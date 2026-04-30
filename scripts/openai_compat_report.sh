#!/usr/bin/env bash

set -euo pipefail

# OpenAI Chat Completions compatibility checks using curl + jq.
#
# This is a manual/local guardrail, not a CI job: it needs a running Osaurus
# server and a usable model. It records request/response artifacts so response
# writer and request validation changes can be compared across runs.

HOST=${HOST:-"http://localhost:1337"}
MODEL=${MODEL:-""}
REQUIRE_TOOL_CALLS=${REQUIRE_TOOL_CALLS:-0}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${0}}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR=${OUT_DIR:-"$REPO_ROOT/results/openai_compat"}
REPORT=${REPORT:-"$REPO_ROOT/results/openai_compat_report.md"}

mkdir -p "$OUT_DIR" "$(dirname "$REPORT")"

TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "$TMP_DIR" >/dev/null 2>&1 || true; }
trap cleanup EXIT

RESULTS_TSV="$TMP_DIR/results.tsv"
: > "$RESULTS_TSV"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing dependency: $1" >&2
    echo "Please install it and re-run." >&2
    exit 1
  fi
}

need curl
need jq

log() {
  printf "%-7s %s\n" "$1" "$2"
}

record() {
  local key="$1"
  local status="$2"
  local area="$3"
  local notes="$4"
  printf '%s\t%s\t%s\t%s\n' "$key" "$status" "$area" "$notes" >> "$RESULTS_TSV"
  log "$status" "$area"
}

artifact_path() {
  local name="$1"
  printf '%s/%s' "$OUT_DIR" "$name"
}

header_status() {
  awk '/^HTTP/{status=$2} END{print status}' "$1"
}

header_content_type_includes() {
  local headers="$1"
  local needle="$2"
  grep -i '^content-type:' "$headers" | grep -qi "$needle"
}

json_array_from_jsonl() {
  local jsonl="$1"
  if [[ -s "$jsonl" ]]; then
    jq -s '.' "$jsonl"
  else
    printf '[]\n'
  fi
}

post_json() {
  local name="$1"
  local path="$2"
  local payload="$3"
  local accept="${4:-application/json}"
  local headers body status

  headers="$(artifact_path "${name}_headers.txt")"
  body="$(artifact_path "${name}_body.txt")"
  printf '%s\n' "$payload" > "$(artifact_path "${name}_request.json")"

  status=$(
    curl -sS -N \
      -D "$headers" \
      -H "Accept: $accept" \
      -H 'Content-Type: application/json' \
      -X POST "$HOST$path" \
      -d "$payload" \
      -o "$body" \
      -w '%{http_code}'
  )

  printf '%s' "$status" > "$(artifact_path "${name}_status.txt")"
}

filter_sse_to_jsonl() {
  local sse_body="$1"
  local jsonl_out="$2"
  awk '/^data: /{print substr($0,7)}' "$sse_body" \
    | jq -Rrc 'select(. != "[DONE]") | try fromjson catch empty' > "$jsonl_out" || true
}

get_model() {
  if [[ -n "$MODEL" ]]; then
    printf '%s\n' "$MODEL"
    return
  fi

  local models_json ids
  models_json=$(curl -sS "$HOST/v1/models" || curl -sS "$HOST/models" || true)
  if [[ -z "$models_json" ]]; then
    printf '\n'
    return
  fi

  ids=$(jq -r '.data[]?.id // empty' <<<"$models_json")
  if grep -qx 'foundation' <<<"$ids"; then
    printf 'foundation\n'
  elif [[ -n "$ids" ]]; then
    head -n1 <<<"$ids"
  else
    printf '\n'
  fi
}

expect_status() {
  local headers="$1"
  local expected="$2"
  [[ "$(header_status "$headers")" == "$expected" ]]
}

nonstreaming_chat_test() {
  local model="$1"
  local name="chat_nonstream"
  local payload headers body ok finish

  payload=$(jq -nc --arg m "$model" '{
    model: $m,
    messages: [{role:"user", content:"Say hello in one short sentence."}],
    stream: false,
    temperature: 0.2,
    max_tokens: 64
  }')

  post_json "$name" "/v1/chat/completions" "$payload"
  headers="$(artifact_path "${name}_headers.txt")"
  body="$(artifact_path "${name}_body.txt")"

  ok=true
  expect_status "$headers" 200 || ok=false
  jq -e '.object == "chat.completion"' "$body" >/dev/null 2>&1 || ok=false
  jq -e '.choices[0].message.role == "assistant"' "$body" >/dev/null 2>&1 || ok=false
  jq -e '(.choices[0].message.content // "") | length > 0' "$body" >/dev/null 2>&1 || ok=false
  finish=$(jq -r '.choices[0].finish_reason // empty' "$body" 2>/dev/null || true)
  [[ "$finish" == "stop" ]] || ok=false

  if $ok; then
    record "chat_nonstream" "PASS" "Chat completions non-streaming" "object/message/finish_reason=stop"
  else
    record "chat_nonstream" "FAIL" "Chat completions non-streaming" "see ${name}_*.txt/json artifacts"
  fi
}

streaming_chat_test() {
  local model="$1"
  local name="chat_stream"
  local payload headers body jsonl chunks ok finish role

  payload=$(jq -nc --arg m "$model" '{
    model: $m,
    messages: [{role:"user", content:"Say hello in one short sentence."}],
    stream: true,
    temperature: 0.2,
    max_tokens: 64
  }')

  post_json "$name" "/v1/chat/completions" "$payload" "text/event-stream"
  headers="$(artifact_path "${name}_headers.txt")"
  body="$(artifact_path "${name}_body.txt")"
  jsonl="$(artifact_path "${name}_chunks.jsonl")"
  filter_sse_to_jsonl "$body" "$jsonl"
  chunks=$(json_array_from_jsonl "$jsonl")

  ok=true
  expect_status "$headers" 200 || ok=false
  header_content_type_includes "$headers" 'text/event-stream' || ok=false
  grep -q '^data: \[DONE\]$' "$body" || ok=false
  jq -e 'length > 0 and all(.object == "chat.completion.chunk")' <<<"$chunks" >/dev/null 2>&1 || ok=false
  role=$(jq -r '.[0].choices[0].delta.role // empty' <<<"$chunks" 2>/dev/null || true)
  [[ "$role" == "assistant" ]] || ok=false
  jq -e 'map(.choices[0].delta.content // empty) | join("") | length > 0' <<<"$chunks" >/dev/null 2>&1 || ok=false
  finish=$(jq -r '.[-1].choices[0].finish_reason // empty' <<<"$chunks" 2>/dev/null || true)
  [[ "$finish" == "stop" ]] || ok=false

  if $ok; then
    record "chat_stream" "PASS" "Chat completions streaming" "SSE framing, assistant role, content deltas, finish_reason=stop"
  else
    record "chat_stream" "FAIL" "Chat completions streaming" "see ${name}_*.txt/jsonl artifacts"
  fi
}

tool_call_streaming_test() {
  local model="$1"
  local name="tool_stream"
  local payload headers body jsonl chunks supported compliant

  payload=$(jq -nc --arg m "$model" '{
    model: $m,
    messages: [{role:"user", content:"Using tools if available, get weather for city=San Francisco."}],
    tools: [{
      type: "function",
      function: {
        name: "get_weather",
        description: "Get weather by city",
        parameters: {
          type: "object",
          properties: { city: { type: "string" } },
          required: ["city"]
        }
      }
    }],
    tool_choice: "auto",
    stream: true,
    temperature: 0.0,
    max_tokens: 64
  }')

  post_json "$name" "/v1/chat/completions" "$payload" "text/event-stream"
  headers="$(artifact_path "${name}_headers.txt")"
  body="$(artifact_path "${name}_body.txt")"
  jsonl="$(artifact_path "${name}_chunks.jsonl")"
  filter_sse_to_jsonl "$body" "$jsonl"
  chunks=$(json_array_from_jsonl "$jsonl")

  supported=false
  compliant=false

  if expect_status "$headers" 200 \
    && header_content_type_includes "$headers" 'text/event-stream' \
    && grep -q '^data: \[DONE\]$' "$body" \
    && jq -e 'map(.choices[0].delta.tool_calls[0] // empty) | any' <<<"$chunks" >/dev/null 2>&1
  then
    supported=true
    if jq -e 'map(.choices[0].delta.tool_calls[0] // empty)
              | any((.id != null) and (.function.name != null))' <<<"$chunks" >/dev/null 2>&1 \
      && jq -e 'map(.choices[0].delta.tool_calls[0].function.arguments // empty)
                | any((type == "string") and (length > 0))' <<<"$chunks" >/dev/null 2>&1 \
      && [[ "$(jq -r '.[-1].choices[0].finish_reason // empty' <<<"$chunks" 2>/dev/null || true)" == "tool_calls" ]]
    then
      compliant=true
    fi
  fi

  if $supported && $compliant; then
    record "tool_stream" "PASS" "Tool calling streaming" "OpenAI-style id/name/arguments deltas with finish_reason=tool_calls"
  elif $supported; then
    record "tool_stream" "FAIL" "Tool calling streaming" "tool deltas observed but schema is incomplete"
  elif [[ "$REQUIRE_TOOL_CALLS" == "1" ]]; then
    record "tool_stream" "FAIL" "Tool calling streaming" "not observed and REQUIRE_TOOL_CALLS=1"
  else
    record "tool_stream" "WARN" "Tool calling streaming" "not observed; current model may not support tool calls"
  fi
}

request_validation_error_test() {
  local model="$1"
  local name="request_validation_error"
  local payload headers body ok status

  payload=$(jq -nc --arg m "$model" '{
    model: $m,
    messages: [{role:"user", content:"hello"}],
    stream: false,
    n: 2
  }')

  post_json "$name" "/v1/chat/completions" "$payload"
  headers="$(artifact_path "${name}_headers.txt")"
  body="$(artifact_path "${name}_body.txt")"
  status=$(header_status "$headers")

  ok=true
  [[ "$status" == "400" || "$status" == "422" ]] || ok=false
  jq -e '.error.message | type == "string" and length > 0' "$body" >/dev/null 2>&1 || ok=false

  if $ok; then
    record "request_validation_error" "PASS" "Unsupported request validation" "n>1 rejected with JSON error message"
  else
    record "request_validation_error" "FAIL" "Unsupported request validation" "expected HTTP 400/422 JSON error for n>1"
  fi
}

write_report() {
  local model="$1"
  {
    echo "## OpenAI Chat Completions Compatibility"
    echo "- **Server**: $HOST"
    echo "- **Model**: \`$model\`"
    echo "- **Artifacts**: \`$OUT_DIR\`"
    echo ""
    echo "### Results"
    echo "| Area | Status | Notes |"
    echo "| --- | ---: | --- |"
    awk -F '\t' '{ printf "| %s | %s | %s |\n", $3, $2, $4 }' "$RESULTS_TSV"
    echo ""
    echo "### Artifact Naming"
    echo ""
    echo "Each check writes:"
    echo ""
    echo "- \`*_request.json\`"
    echo "- \`*_headers.txt\`"
    echo "- \`*_status.txt\`"
    echo "- \`*_body.txt\`"
    echo "- \`*_chunks.jsonl\` for streaming checks"
    echo ""
    echo "Set \`OUT_DIR=build/compat/openai\` to keep generated artifacts out of tracked \`results/\` files."
  } > "$REPORT"

  echo ""
  echo "Report written to: $REPORT"
}

main() {
  local model failures

  model=$(get_model)
  if [[ -z "$model" ]]; then
    echo "Could not determine a model from $HOST/v1/models. Set MODEL=... and retry." >&2
    exit 2
  fi

  echo "Using server: $HOST"
  echo "Using model:  $model"
  echo "Artifacts:    $OUT_DIR"
  echo ""

  nonstreaming_chat_test "$model"
  streaming_chat_test "$model"
  tool_call_streaming_test "$model"
  request_validation_error_test "$model"
  write_report "$model"

  failures=$(awk -F '\t' '$2 == "FAIL" { count++ } END { print count + 0 }' "$RESULTS_TSV")
  if [[ "$failures" != "0" ]]; then
    echo "$failures compatibility check(s) failed." >&2
    exit 1
  fi
}

main "$@"
