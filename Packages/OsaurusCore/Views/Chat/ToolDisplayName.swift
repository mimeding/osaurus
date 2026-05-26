//
//  ToolDisplayName.swift
//  osaurus
//
//  Maps technical tool names (`db_insert`, `sandbox_exec`, …) to friendly,
//  present-tense labels for the collapsed tool chip so non-technical users
//  read "Inserting into the database" instead of `db_insert`. The raw
//  technical name is still shown verbatim once the row is expanded.
//
//  Built-in tools get curated phrasing; anything dynamic (plugin / MCP /
//  folder / sandbox-registered tools that aren't in the table) falls back to
//  a generic snake_case → "Snake case" humanizer.
//

import Foundation

enum ToolDisplayName {

    /// Friendly label for the collapsed chip. Returns a curated phrase for
    /// known tools, otherwise a humanized form of `rawName`.
    static func friendly(for rawName: String) -> String {
        if let mapped = curated[rawName] { return mapped }
        // Uncurated sandbox tools (e.g. dynamically registered plugins) still
        // get the "in sandbox" suffix for context.
        if rawName.hasPrefix("sandbox_") {
            return humanize(String(rawName.dropFirst("sandbox_".count))) + L(" in sandbox")
        }
        return humanize(rawName)
    }

    /// Generic fallback: underscores/dashes → spaces, sentence-cased.
    /// `weather_lookup` → "Weather lookup". Keeps arbitrary plugin/MCP names
    /// readable without a curated entry.
    private static func humanize(_ raw: String) -> String {
        let spaced =
            raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = spaced.first else { return raw }
        return first.uppercased() + spaced.dropFirst()
    }

    /// Curated labels for built-in tools. Agent-loop tools (`todo`,
    /// `complete`, `clarify`) are listed for completeness even though they
    /// render as first-class UI rather than chips.
    private static let curated: [String: String] = [
        // Database
        "db_schema": L("Reading the database schema"),
        "db_create_table": L("Creating a database table"),
        "db_alter_table": L("Updating a table’s structure"),
        "db_insert": L("Inserting into the database"),
        "db_upsert": L("Saving to the database"),
        "db_update": L("Updating the database"),
        "db_delete": L("Deleting from the database"),
        "db_query": L("Querying the database"),
        "db_execute": L("Running a database command"),
        "db_migrate": L("Migrating the database"),
        "db_restore": L("Restoring the database"),
        "db_define_view": L("Defining a database view"),
        "db_drop_view": L("Removing a database view"),
        "db_list_views": L("Listing database views"),
        "db_run_view": L("Running a database view"),

        // Sandbox — "in sandbox" suffix makes the execution context explicit.
        "sandbox_exec": L("Running a command in sandbox"),
        "sandbox_execute_code": L("Running code in sandbox"),
        "sandbox_read_file": L("Reading a file in sandbox"),
        "sandbox_write_file": L("Writing a file in sandbox"),
        "sandbox_edit_file": L("Editing a file in sandbox"),
        "sandbox_search_files": L("Searching files in sandbox"),
        "sandbox_install": L("Installing dependencies in sandbox"),
        "sandbox_npm_install": L("Installing npm packages in sandbox"),
        "sandbox_pip_install": L("Installing Python packages in sandbox"),
        "sandbox_process": L("Managing a process in sandbox"),
        "sandbox_plugin_register": L("Registering a plugin in sandbox"),
        "sandbox_secret_check": L("Checking a secret in sandbox"),
        "sandbox_secret_set": L("Saving a secret in sandbox"),

        // Folder / file
        "file_read": L("Reading a file"),
        "file_write": L("Writing a file"),
        "file_edit": L("Editing a file"),
        "file_search": L("Searching files"),
        "file_tree": L("Browsing files"),
        "shell_run": L("Running a command"),
        "git_status": L("Checking git status"),
        "git_diff": L("Viewing changes"),
        "git_commit": L("Committing changes"),

        // General built-ins
        "capabilities_search": L("Searching capabilities"),
        "capabilities_load": L("Loading capabilities"),
        "search_memory": L("Searching memory"),
        "render_chart": L("Rendering a chart"),
        "share_artifact": L("Sharing a file"),
        "speak": L("Speaking"),
        "notify": L("Sending a notification"),
        "schedule_next_run": L("Scheduling the next run"),
        "cancel_next_run": L("Canceling the scheduled run"),

        // Agent-loop (rendered as first-class UI, listed for completeness)
        "todo": L("Updating the task list"),
        "complete": L("Finishing up"),
        "clarify": L("Asking a question"),
    ]
}
