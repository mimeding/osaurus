import SwiftUI

// MARK: - Cache Settings UI Helpers

/// Three-state Bool picker used for optional cache-engine toggles.
/// Auto = fall back to vmlx-swift-lm default, Enabled/Disabled = explicit override.
enum CacheTriState: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case enabled = "Enabled"
    case disabled = "Disabled"

    var id: String { rawValue }

    /// Convert to `Bool?` for `ServerCacheConfig` storage.
    var optionalBool: Bool? {
        switch self {
        case .auto: return nil
        case .enabled: return true
        case .disabled: return false
        }
    }

    /// Hydrate from `Bool?` on view load.
    static func from(_ value: Bool?) -> CacheTriState {
        switch value {
        case .none: return .auto
        case .some(true): return .enabled
        case .some(false): return .disabled
        }
    }
}

/// KV quantization mode picker for the Cache Engine settings section.
///
/// `.auto` maps to `ServerCacheConfig.kvQuantMode = nil`, which osaurus
/// interprets as "use the osaurus default of TurboQuant(3,3)". The UI
/// label makes this explicit so users know what Auto does — otherwise
/// users might assume Auto means "no quant" (the vmlx package default).
enum CacheQuantModeChoice: String, CaseIterable, Identifiable {
    /// Maps to nil → osaurus substitutes `.turboQuant(3, 3)` in makeGenerateParameters.
    case auto = "Auto (TurboQuant)"
    /// Full-precision KV cache. No quantization.
    case off = "Off"
    /// Legacy affine quantization. Tunable via bits + groupSize.
    case affine = "Affine"
    /// TurboQuant with explicit key/value bit settings.
    case turboQuant = "TurboQuant"

    var id: String { rawValue }

    var optionalMode: CacheQuantMode? {
        switch self {
        case .auto: return nil
        case .off: return CacheQuantMode.none
        case .affine: return .affine
        case .turboQuant: return .turboQuant
        }
    }

    static func from(_ value: CacheQuantMode?) -> CacheQuantModeChoice {
        switch value {
        case nil: return .auto
        case .some(CacheQuantMode.none): return .off
        case .some(.affine): return .affine
        case .some(.turboQuant): return .turboQuant
        }
    }
}

/// Paged block size choice. Valid values are 32/64/128 tokens per block;
/// `.auto` defers to the vmlx default (64).
enum CachePagedBlockSizeChoice: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case size32 = "32"
    case size64 = "64"
    case size128 = "128"

    var id: String { rawValue }

    var optionalInt: Int? {
        switch self {
        case .auto: return nil
        case .size32: return 32
        case .size64: return 64
        case .size128: return 128
        }
    }

    static func from(_ value: Int?) -> CachePagedBlockSizeChoice {
        switch value {
        case 32: return .size32
        case 64: return .size64
        case 128: return .size128
        default: return .auto
        }
    }
}

// MARK: - Configuration View
struct ConfigurationView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @EnvironmentObject private var updater: UpdaterViewModel

    /// Use computed property to always get the current theme from ThemeManager
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var tempPortString: String = ""
    @State private var tempExposeToNetwork: Bool = false
    @State private var tempStartAtLogin: Bool = false
    @State private var tempHideDockIcon: Bool = false
    @State private var cliInstallMessage: String? = nil
    @State private var cliInstallSuccess: Bool = false
    @State private var hasAppeared = false
    @State private var successMessage: String?
    @State private var isResetting = false

    // Chat settings state
    @State private var tempChatHotkey: Hotkey? = nil
    @State private var tempSystemPrompt: String = ""
    @State private var tempChatTemperature: String = ""
    @State private var tempChatMaxTokens: String = ""
    @State private var tempChatContextLength: String = ""
    @State private var tempChatTopP: String = ""
    @State private var tempChatMaxToolAttempts: String = ""
    @State private var tempPreflightSearchMode: PreflightSearchMode = .balanced
    @State private var tempDisableTools: Bool = true
    @State private var tempShowChatBarToolsChip: Bool = true
    @State private var tempMemoryEnabled: Bool = false
    @State private var tempCoreModelProvider: String = ""
    @State private var tempCoreModelName: String = ""
    @State private var coreModelPickerItems: [ModelPickerItem] = []
    @State private var tempEnableClipboardMonitoring: Bool = false

    // Work generation settings state
    @State private var tempAgentTemperature: String = ""
    @State private var tempAgentMaxTokens: String = ""
    @State private var tempAgentTopP: String = ""
    @State private var tempAgentMaxIterations: String = ""

    // Server settings state
    @State private var tempAllowedOrigins: String = ""

    // Local Inference settings state
    @State private var tempTopP: String = ""
    @State private var tempMaxKV: String = ""
    @State private var tempEvictionPolicy: ModelEvictionPolicy = .strictSingleModel

    // Cache engine overrides — all three-state (nil/true/false for Bools, "" = Auto for numeric).
    // See ServerCacheConfig for the 6-stack breakdown. Empty / .auto means "let vmlx auto-tune".
    // Stack 1
    @State private var tempCachePrefillStepSize: String = ""
    // Stacks 2 + 3
    @State private var tempCacheUsePaged: CacheTriState = .auto
    @State private var tempCacheMaxBlocks: String = ""
    @State private var tempCachePagedBlockSize: CachePagedBlockSizeChoice = .auto
    // Stack 4
    @State private var tempCacheEnableDisk: CacheTriState = .auto
    @State private var tempCacheDiskMaxGB: String = ""
    // Stack 5
    @State private var tempCacheQuantMode: CacheQuantModeChoice = .auto
    @State private var tempCacheAffineBits: String = ""
    @State private var tempCacheAffineGroupSize: String = ""
    @State private var tempCacheTurboKeyBits: String = ""
    @State private var tempCacheTurboValueBits: String = ""
    @State private var tempCacheQuantStart: String = ""
    // Stack 6
    @State private var tempCacheSSMMaxEntries: String = ""
    // Derived / display
    @State private var diskCacheUsageBytes: Int = 0

    // Toast settings state
    @State private var tempToastPosition: ToastPosition = .topRight
    @State private var tempToastTimeout: String = ""
    @State private var tempToastEnabled: Bool = true
    @State private var tempToastMaxVisible: String = ""
    @State private var tempToastMaxConcurrent: String = ""

    // Search (passed from sidebar)
    @Binding var searchText: String

    init(searchText: Binding<String> = .constant("")) {
        self._searchText = searchText
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func matchesSearch(_ texts: String...) -> Bool {
        guard isSearching else { return true }
        return texts.contains { SearchService.matches(query: searchText, in: $0) }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header
                headerView
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : -10)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

                // Scrollable content area
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // MARK: - General Section
                        if matchesSearch(
                            "General",
                            "System",
                            "Hotkey",
                            "Login",
                            "Start at Login",
                            "Beta",
                            "Updates",
                            "Core Model",
                            "CLI",
                            "Command Line",
                            "Install",
                            "Symlink",
                            "Maintenance",
                            "Reset",
                            "Factory Reset",
                            "Wipe"
                        ) {
                            SettingsSection(title: "General", icon: "gear") {
                                VStack(alignment: .leading, spacing: 20) {
                                    Text("Application behavior and system integration.", bundle: .module)
                                        .font(.system(size: 12))
                                        .foregroundColor(theme.secondaryText)

                                    // Global Hotkey
                                    SettingsField(label: "Global Hotkey") {
                                        HotkeyRecorder(value: $tempChatHotkey)
                                    }

                                    // Start at Login
                                    SettingsToggle(
                                        title: L("Start at Login"),
                                        description: "Launch Osaurus when you sign in",
                                        isOn: $tempStartAtLogin
                                    )

                                    SettingsToggle(
                                        title: L("Hide Dock Icon"),
                                        description: "Run in menu bar only (requires restart)",
                                        isOn: $tempHideDockIcon
                                    )

                                    SettingsToggle(
                                        title: L("Beta Updates"),
                                        description:
                                            "Receive pre-release updates with new features before they're generally available",
                                        isOn: $updater.isBetaChannel
                                    )

                                    SettingsDivider()

                                    SettingsSubsection(label: "Core Model") {
                                        VStack(alignment: .leading, spacing: 8) {
                                            coreModelPicker
                                            Text(
                                                "Lightweight model used for memory extraction, preflight search optimization, and other background inference tasks.",
                                                bundle: .module
                                            )
                                            .font(.system(size: 11))
                                            .foregroundColor(theme.tertiaryText)
                                        }
                                    }

                                    SettingsDivider()

                                    // Command Line Tool
                                    SettingsSubsection(label: "Command Line Tool") {
                                        VStack(alignment: .leading, spacing: 12) {
                                            Text(
                                                "Install the `osaurus` CLI into your PATH for terminal access.",
                                                bundle: .module
                                            )
                                            .font(.system(size: 12))
                                            .foregroundColor(theme.tertiaryText)

                                            HStack(spacing: 12) {
                                                Button(action: { installCLI() }) {
                                                    Text("Install CLI", bundle: .module)
                                                }
                                                .buttonStyle(SettingsButtonStyle())
                                                .help(Text("Create a symlink to the embedded CLI", bundle: .module))

                                                if let message = cliInstallMessage {
                                                    HStack(spacing: 6) {
                                                        Image(
                                                            systemName: cliInstallSuccess
                                                                ? "checkmark.circle.fill"
                                                                : "exclamationmark.triangle.fill"
                                                        )
                                                        .font(.system(size: 12))
                                                        Text(message)
                                                            .font(.system(size: 11))
                                                            .lineLimit(2)
                                                    }
                                                    .foregroundColor(
                                                        cliInstallSuccess ? theme.successColor : theme.warningColor
                                                    )
                                                }
                                            }

                                            Text(
                                                "If installed to ~/.local/bin, ensure it's in your PATH.",
                                                bundle: .module
                                            )
                                            .font(.system(size: 11))
                                            .foregroundColor(theme.tertiaryText)
                                        }
                                    }

                                    SettingsDivider()

                                    // Storage
                                    SettingsSubsection(label: "Storage") {
                                        DirectoryPickerView()
                                    }

                                    SettingsDivider()

                                    // Maintenance
                                    SettingsSubsection(label: "Maintenance") {
                                        VStack(alignment: .leading, spacing: 12) {
                                            Text(
                                                "Troubleshoot or reset the application. A factory reset permanently deletes all data and settings.",
                                                bundle: .module
                                            )
                                            .font(.system(size: 12))
                                            .foregroundColor(theme.tertiaryText)

                                            Button(role: .destructive, action: { showFactoryResetConfirmation() }) {
                                                HStack(spacing: 6) {
                                                    Image(systemName: "trash")
                                                        .font(.system(size: 12))
                                                    Text("Factory Reset…", bundle: .module)
                                                }
                                            }
                                            .buttonStyle(SettingsButtonStyle(isDestructive: true))
                                        }
                                    }
                                }
                            }
                        }

                        // MARK: - Chat Section
                        if matchesSearch(
                            "Chat",
                            "System Prompt",
                            "Temperature",
                            "Max Tokens",
                            "Context Length",
                            "Top P",
                            "Max Tool Attempts",
                            "Generation",
                            "Preflight",
                            "Capability Search",
                            "Memory",
                            "Tools"
                        ) {
                            SettingsSection(title: "Chat", icon: "message") {
                                VStack(alignment: .leading, spacing: 20) {
                                    Text("Configure how chat mode generates responses.", bundle: .module)
                                        .font(.system(size: 12))
                                        .foregroundColor(theme.secondaryText)

                                    // System Prompt
                                    StyledSettingsTextArea(
                                        label: "System Prompt",
                                        text: $tempSystemPrompt,
                                        placeholder: "Enter instructions for all chats...",
                                        hint: "Optional. Shown as a system message for all chats."
                                    )

                                    // Generation Settings
                                    SettingsSubsection(label: "Generation") {
                                        VStack(alignment: .leading, spacing: 12) {
                                            SettingsSliderField(
                                                label: "Temperature",
                                                help: "Randomness (0–2). Higher = more creative",
                                                text: $tempChatTemperature,
                                                range: 0 ... 2,
                                                step: 0.1,
                                                defaultValue: 0.7,
                                                formatString: "%.1f"
                                            )
                                            SettingsStepperField(
                                                label: "Max Tokens",
                                                help: "Maximum response tokens",
                                                text: $tempChatMaxTokens,
                                                range: 1 ... 65536,
                                                step: 1024,
                                                defaultValue: 16384
                                            )
                                            SettingsStepperField(
                                                label: "Context Length",
                                                help: "Context window for remote models",
                                                text: $tempChatContextLength,
                                                range: 2048 ... 256000,
                                                step: 1024,
                                                defaultValue: 128000
                                            )
                                            SettingsSliderField(
                                                label: "Top P Override",
                                                help: "Sampling diversity (0–1)",
                                                text: $tempChatTopP,
                                                range: 0 ... 1,
                                                step: 0.05,
                                                defaultValue: 1.0,
                                                formatString: "%.2f"
                                            )
                                            SettingsStepperField(
                                                label: "Max Tool Attempts",
                                                help: "Max consecutive tool calls per turn",
                                                text: $tempChatMaxToolAttempts,
                                                range: 1 ... 50,
                                                step: 1,
                                                defaultValue: 15
                                            )
                                        }
                                    }

                                    SettingsDivider()

                                    SettingsSubsection(label: "Capability Search") {
                                        VStack(alignment: .leading, spacing: 10) {
                                            Picker("", selection: $tempPreflightSearchMode) {
                                                ForEach(PreflightSearchMode.allCases, id: \.self) { mode in
                                                    Text(mode.rawValue.capitalized).tag(mode)
                                                }
                                            }
                                            .pickerStyle(.segmented)
                                            .labelsHidden()
                                            .disabled(tempDisableTools)

                                            Text(tempPreflightSearchMode.helpText)
                                                .font(.system(size: 11))
                                                .foregroundColor(theme.tertiaryText)
                                        }
                                    }

                                    SettingsDivider()

                                    SettingsSubsection(label: "Tools") {
                                        VStack(alignment: .leading, spacing: 10) {
                                            Toggle(isOn: $tempDisableTools) {
                                                Text("Disable tools", bundle: .module)
                                                    .font(.system(size: 12))
                                            }
                                            Text(
                                                "Send messages directly to the model with no tool specs or capability injection. Tools are off by default — enable them here or via the chat bar to let agents use built-in and plugin tools.",
                                                bundle: .module
                                            )
                                            .font(.system(size: 11))
                                            .foregroundColor(theme.tertiaryText)

                                            Toggle(isOn: $tempShowChatBarToolsChip) {
                                                Text("Show Tools chip in chat bar", bundle: .module)
                                                    .font(.system(size: 12))
                                            }
                                            Text(
                                                "Render a per-conversation Tools toggle chip in the chat input bar. Turn off for a cleaner chat UI when you manage tools exclusively from Settings.",
                                                bundle: .module
                                            )
                                            .font(.system(size: 11))
                                            .foregroundColor(theme.tertiaryText)
                                        }
                                    }

                                    SettingsDivider()

                                    SettingsSubsection(label: "Memory") {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Toggle(isOn: $tempMemoryEnabled) {
                                                Text("Enable memory", bundle: .module)
                                                    .font(.system(size: 12))
                                            }
                                            Text(
                                                "Inject persistent memory (profile, working memory, summaries, relationships) into the system prompt. Off by default — memory can add thousands of tokens per request. Enable for agents that need long-term context across conversations.",
                                                bundle: .module
                                            )
                                            .font(.system(size: 11))
                                            .foregroundColor(theme.tertiaryText)
                                        }
                                    }

                                    SettingsDivider()

                                    SettingsSubsection(label: "Clipboard") {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Toggle(isOn: $tempEnableClipboardMonitoring) {
                                                Text("Enable clipboard monitoring", bundle: .module)
                                                    .font(.system(size: 12))
                                            }
                                            Text(
                                                "Automatically detect and offer text from any app as context. Includes 'grab selection' feature when summoning Osaurus.",
                                                bundle: .module
                                            )
                                            .font(.system(size: 11))
                                            .foregroundColor(theme.tertiaryText)
                                        }
                                    }

                                }
                            }
                        }

                        // MARK: - Work Section
                        if matchesSearch(
                            "Work",
                            "Work Generation",
                            "Temperature",
                            "Max Tokens",
                            "Top P",
                            "Max Iterations",
                            "Folder",
                            "File",
                            "Shell",
                            "Git",
                            "Permissions",
                            "Write",
                            "Delete",
                            "Move",
                            "Copy"
                        ) {
                            AgentSettingsSection(
                                workTemperature: $tempAgentTemperature,
                                workMaxTokens: $tempAgentMaxTokens,
                                agentTopP: $tempAgentTopP,
                                workMaxIterations: $tempAgentMaxIterations
                            )
                        }

                        // MARK: - Server Section
                        if matchesSearch("Server", "Port", "Network", "Expose", "CORS", "Origins", "Allowed Origins") {
                            SettingsSection(title: "Server", icon: "network") {
                                VStack(alignment: .leading, spacing: 20) {
                                    Text("Configure the local API server for external integrations.", bundle: .module)
                                        .font(.system(size: 12))
                                        .foregroundColor(theme.secondaryText)

                                    // Port
                                    SettingsStepperField(
                                        label: "Port",
                                        help: "Port number (1–65535)",
                                        text: $tempPortString,
                                        range: 1 ... 65535,
                                        step: 1,
                                        defaultValue: 1337
                                    )

                                    // Network Exposure Toggle
                                    SettingsToggle(
                                        title: L("Expose to Network"),
                                        description: "Allow devices on your network to connect",
                                        isOn: $tempExposeToNetwork
                                    )

                                    // CORS Settings
                                    StyledSettingsTextField(
                                        label: "Allowed Origins",
                                        text: $tempAllowedOrigins,
                                        placeholder: "https://example.com, https://app.localhost",
                                        help: "Comma-separated list. Use * for any, empty to disable CORS"
                                    )
                                }
                            }
                        }

                        // MARK: - Local Inference Section
                        if matchesSearch(
                            "Local Inference",
                            "Inference",
                            "Sampling",
                            "Top P",
                            "KV Cache",
                            "Max KV",
                            "CPU",
                            "Memory"
                        ) {
                            SettingsSection(title: "Local Inference", icon: "bolt") {
                                VStack(alignment: .leading, spacing: 20) {
                                    Text(
                                        "Tune the local model runtime. These settings only affect models running on this device.",
                                        bundle: .module
                                    )
                                    .font(.system(size: 12))
                                    .foregroundColor(theme.secondaryText)

                                    // Sampling
                                    SettingsSubsection(label: "Sampling") {
                                        VStack(alignment: .leading, spacing: 12) {
                                            SettingsSliderField(
                                                label: "Top P",
                                                help: "Default sampling diversity (0–1)",
                                                text: $tempTopP,
                                                range: 0 ... 1,
                                                step: 0.05,
                                                defaultValue: 1.0,
                                                formatString: "%.2f"
                                            )
                                        }
                                    }

                                    // KV Cache Settings
                                    SettingsSubsection(label: "KV Cache") {
                                        VStack(alignment: .leading, spacing: 12) {
                                            SettingsStepperField(
                                                label: "Max Context Length",
                                                help: "Max KV cache size in tokens",
                                                text: $tempMaxKV,
                                                range: 1024 ... 131072,
                                                step: 1024,
                                                defaultValue: 8192
                                            )
                                        }
                                    }

                                    SettingsDivider()

                                    // Eviction Policy
                                    SettingsSubsection(label: "Model Management") {
                                        VStack(alignment: .leading, spacing: 10) {
                                            Picker("", selection: $tempEvictionPolicy) {
                                                ForEach(ModelEvictionPolicy.allCases, id: \.self) { policy in
                                                    Text(policy.rawValue).tag(policy)
                                                }
                                            }
                                            .pickerStyle(.segmented)
                                            .labelsHidden()

                                            Text(tempEvictionPolicy.description)
                                                .font(.system(size: 11))
                                                .foregroundColor(theme.tertiaryText)
                                        }
                                    }

                                    SettingsDivider()

                                    cacheEngineSubsection
                                }
                            }
                        }

                        // MARK: - Voice Section
                        if matchesSearch("Voice", "Parakeet", "Transcription", "Model", "Speech") {
                            VoiceSettingsSection()
                        }

                        // MARK: - Notifications Section
                        if matchesSearch(
                            "Notifications",
                            "Toast",
                            "Position",
                            "Timeout",
                            "Alerts",
                            "Concurrent",
                            "Background"
                        ) {
                            SettingsSection(title: "Notifications", icon: "bell") {
                                VStack(alignment: .leading, spacing: 20) {
                                    // Enable Toasts Toggle
                                    SettingsToggle(
                                        title: L("Show Toast Notifications"),
                                        description: "Display notifications for background tasks and events",
                                        isOn: $tempToastEnabled
                                    )
                                    .onChange(of: tempToastEnabled) { _, _ in
                                        saveToastConfig()
                                    }

                                    // Position Picker
                                    SettingsField(
                                        label: "Toast Position",
                                        hint: "Where toasts appear on screen"
                                    ) {
                                        ToastPositionPicker(selection: $tempToastPosition)
                                            .onChange(of: tempToastPosition) { _, _ in
                                                saveToastConfig()
                                            }
                                    }

                                    // Timeout
                                    StyledSettingsTextField(
                                        label: "Default Timeout",
                                        text: $tempToastTimeout,
                                        placeholder: "5.0",
                                        help: "Seconds before auto-dismiss. Empty uses default 5s"
                                    )
                                    .onChange(of: tempToastTimeout) { _, _ in
                                        saveToastConfig()
                                    }

                                    // Max Visible
                                    StyledSettingsTextField(
                                        label: "Max Visible Toasts",
                                        text: $tempToastMaxVisible,
                                        placeholder: "5",
                                        help: "Maximum toasts shown at once. Empty uses default 5"
                                    )
                                    .onChange(of: tempToastMaxVisible) { _, _ in
                                        saveToastConfig()
                                    }

                                    // Max Concurrent Background Tasks
                                    StyledSettingsTextField(
                                        label: "Max Concurrent Tasks",
                                        text: $tempToastMaxConcurrent,
                                        placeholder: "5",
                                        help: "Maximum background tasks running at once. Empty uses default 5"
                                    )
                                    .onChange(of: tempToastMaxConcurrent) { _, _ in
                                        saveToastConfig()
                                    }

                                    // Test Toast Button
                                    HStack {
                                        Spacer()
                                        Button(action: showTestToast) {
                                            HStack(spacing: 6) {
                                                Image(systemName: "bell.badge")
                                                    .font(.system(size: 12))
                                                Text("Test Toast", bundle: .module)
                                                    .font(.system(size: 12, weight: .medium))
                                            }
                                        }
                                        .buttonStyle(SettingsButtonStyle())
                                    }
                                }
                            }
                        }

                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
                .opacity(hasAppeared ? 1 : 0)
            }

            // Success toast overlay
            if let message = successMessage {
                VStack {
                    Spacer()
                    ThemedToastView(message, type: .success)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 20)
                }
            }

            // Factory reset loading overlay
            if isResetting {
                ZStack {
                    Rectangle()
                        .fill(.regularMaterial)
                        .ignoresSafeArea()

                    VStack(spacing: 24) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(theme.accentColor)

                        VStack(spacing: 8) {
                            Text("Resetting Osaurus", bundle: .module)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(theme.primaryText)

                            Text("Deleting data and preferences. Please wait…", bundle: .module)
                                .font(.system(size: 14))
                                .foregroundColor(theme.secondaryText)
                        }
                    }
                    .padding(40)
                    .background(
                        RoundedRectangle(cornerRadius: 24)
                            .fill(theme.cardBackground)
                            .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 10)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(theme.cardBorder, lineWidth: 1)
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(100)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            loadConfiguration()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .onReceive(ModelPickerItemCache.shared.$items) { options in
            coreModelPickerItems = options
        }
    }

    // MARK: - Success Toast

    private func showSuccess(_ message: String) {
        withAnimation(theme.springAnimation()) {
            successMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(theme.animationQuick()) {
                successMessage = nil
            }
        }
    }

    /// Surface a save failure to the user as a red toast via ToastManager.
    /// Logs the error as well so it shows up in Console.app for post-mortem.
    /// Called from `saveConfiguration` when any of the throwing store
    /// writes fail (disk full, permissions, lock conflicts, etc.).
    /// See `05-CONFIGURABILITY-AUDIT.md` Issue 10 — silently swallowing
    /// these errors lets users believe their settings saved when they
    /// didn't.
    private func showSaveError(_ message: String, error: Error) {
        print("[Osaurus] \(message): \(error)")
        ToastManager.shared.error(
            message,
            message: error.localizedDescription
        )
    }

    // MARK: - Header View

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("Settings"),
            subtitle: L("Configure your Osaurus settings")
        ) {
            HeaderSecondaryButton("Restore View Defaults", icon: "arrow.counterclockwise") {
                resetToDefaults()
            }
            .help(
                Text(
                    "Restore view-only settings to recommended defaults (does not affect saved configuration)",
                    bundle: .module
                )
            )
            HeaderPrimaryButton("Save Changes", icon: "checkmark") {
                saveConfiguration()
            }
        }
    }

    // MARK: - Configuration Loading

    private func loadConfiguration() {
        let configuration = ServerConfigurationStore.load() ?? ServerConfiguration.default
        tempPortString = String(configuration.port)
        tempExposeToNetwork = configuration.exposeToNetwork
        tempStartAtLogin = configuration.startAtLogin
        tempHideDockIcon = configuration.hideDockIcon

        let chat = ChatConfigurationStore.load()
        tempChatHotkey = chat.hotkey
        tempSystemPrompt = chat.systemPrompt
        tempChatTemperature = chat.temperature.map { String($0) } ?? ""
        tempChatMaxTokens = chat.maxTokens.map(String.init) ?? ""
        tempChatContextLength = chat.contextLength.map(String.init) ?? ""
        tempChatTopP = chat.topPOverride.map { String($0) } ?? ""
        tempChatMaxToolAttempts = chat.maxToolAttempts.map(String.init) ?? ""
        tempPreflightSearchMode = chat.preflightSearchMode ?? .balanced
        tempDisableTools = chat.disableTools
        tempShowChatBarToolsChip = chat.showChatBarToolsChip
        tempMemoryEnabled = MemoryConfigurationStore.load().enabled
        tempCoreModelProvider = chat.coreModelProvider ?? ""
        tempCoreModelName = chat.coreModelName ?? ""
        tempEnableClipboardMonitoring = chat.enableClipboardMonitoring

        // Work generation settings
        tempAgentTemperature = chat.workTemperature.map { String($0) } ?? ""
        tempAgentMaxTokens = chat.workMaxTokens.map(String.init) ?? ""
        tempAgentTopP = chat.workTopPOverride.map { String($0) } ?? ""
        tempAgentMaxIterations = chat.workMaxIterations.map(String.init) ?? ""

        let defaults = ServerConfiguration.default
        tempTopP = configuration.genTopP == defaults.genTopP ? "" : String(configuration.genTopP)
        tempMaxKV = configuration.genMaxKVSize.map(String.init) ?? ""
        tempAllowedOrigins = configuration.allowedOrigins.joined(separator: ", ")
        tempEvictionPolicy = configuration.modelEvictionPolicy

        // Hydrate cache engine overrides. Empty-string and .auto both mean
        // "fall back to vmlx-swift-lm auto-tune" — the UI never shows a
        // computed default in the field; it shows blank so the user knows
        // they're on Auto. This matches the pattern used for tempTopP and
        // tempMaxKV above.
        let cache = configuration.cacheConfig
        tempCachePrefillStepSize = cache.prefillStepSize.map(String.init) ?? ""
        tempCacheUsePaged = CacheTriState.from(cache.usePagedCache)
        tempCacheMaxBlocks = cache.maxCacheBlocks.map(String.init) ?? ""
        tempCachePagedBlockSize = CachePagedBlockSizeChoice.from(cache.pagedBlockSize)
        tempCacheEnableDisk = CacheTriState.from(cache.enableDiskCache)
        tempCacheDiskMaxGB = cache.diskCacheMaxGB.map { String(format: "%.1f", $0) } ?? ""
        tempCacheQuantMode = CacheQuantModeChoice.from(cache.kvQuantMode)
        tempCacheAffineBits = cache.affineKVBits.map(String.init) ?? ""
        tempCacheAffineGroupSize = cache.affineKVGroupSize.map(String.init) ?? ""
        tempCacheTurboKeyBits = cache.turboKeyBits.map(String.init) ?? ""
        tempCacheTurboValueBits = cache.turboValueBits.map(String.init) ?? ""
        tempCacheQuantStart = cache.quantizedKVStart.map(String.init) ?? ""
        tempCacheSSMMaxEntries = cache.ssmMaxEntries.map(String.init) ?? ""
        diskCacheUsageBytes = OsaurusPaths.diskKVCacheUsageBytes()

        // Load toast configuration
        let toastConfig = ToastConfigurationStore.load()
        tempToastPosition = toastConfig.position
        tempToastEnabled = toastConfig.enabled
        let toastDefaults = ToastConfiguration.default
        tempToastTimeout =
            toastConfig.defaultTimeout == toastDefaults.defaultTimeout
            ? "" : String(toastConfig.defaultTimeout)
        tempToastMaxVisible =
            toastConfig.maxVisibleToasts == toastDefaults.maxVisibleToasts
            ? "" : String(toastConfig.maxVisibleToasts)
        tempToastMaxConcurrent =
            toastConfig.maxConcurrentTasks == toastDefaults.maxConcurrentTasks
            ? "" : String(toastConfig.maxConcurrentTasks)
    }

    // MARK: - Reset to Defaults

    private func resetToDefaults() {
        let serverDefaults = ServerConfiguration.default
        let chatDefaults = ChatConfiguration.default

        tempPortString = String(serverDefaults.port)
        tempExposeToNetwork = serverDefaults.exposeToNetwork
        tempStartAtLogin = serverDefaults.startAtLogin
        tempHideDockIcon = serverDefaults.hideDockIcon
        tempAllowedOrigins = ""

        tempChatHotkey = chatDefaults.hotkey
        tempSystemPrompt = ""
        tempChatTemperature = ""
        tempChatMaxTokens = ""
        tempChatContextLength = ""
        tempChatTopP = ""
        tempChatMaxToolAttempts = ""
        tempPreflightSearchMode = .balanced
        tempDisableTools = true
        tempShowChatBarToolsChip = true
        tempMemoryEnabled = false
        tempCoreModelProvider = ""
        tempCoreModelName = ""
        tempEnableClipboardMonitoring = chatDefaults.enableClipboardMonitoring
        tempAgentTemperature = ""
        tempAgentMaxTokens = ""
        tempAgentTopP = ""
        tempAgentMaxIterations = ""

        tempTopP = ""
        tempMaxKV = ""
        tempEvictionPolicy = serverDefaults.modelEvictionPolicy

        // Cache engine: back to pure auto-tune (all fields nil). Auto
        // means TurboQuant(3,3) for stack 5 — see makeGenerateParameters.
        tempCachePrefillStepSize = ""
        tempCacheUsePaged = .auto
        tempCacheMaxBlocks = ""
        tempCachePagedBlockSize = .auto
        tempCacheEnableDisk = .auto
        tempCacheDiskMaxGB = ""
        tempCacheQuantMode = .auto
        tempCacheAffineBits = ""
        tempCacheAffineGroupSize = ""
        tempCacheTurboKeyBits = ""
        tempCacheTurboValueBits = ""
        tempCacheQuantStart = ""
        tempCacheSSMMaxEntries = ""

        showSuccess("Settings restored to defaults")
    }

    // MARK: - Factory Reset

    private func showFactoryResetConfirmation() {
        let alert = NSAlert()
        alert.messageText = "Factory Reset Osaurus?"
        alert.informativeText =
            "This will permanently delete all your data, including chat history, agents, memory, and your identity keys. This action cannot be undone and the application will close."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Factory Reset")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Task { @MainActor in
                withAnimation(.easeIn(duration: 0.3)) {
                    isResetting = true
                }
                // Yield to allow UI to update before heavy deletion starts
                try? await Task.sleep(nanoseconds: 100_000_000)
                await OnboardingService.shared.performFactoryReset()
            }
        }
    }

    // MARK: - Configuration Saving

    private func saveConfiguration() {
        guard let port = Int(tempPortString), (1 ..< 65536).contains(port) else { return }

        let previousServerCfg = ServerConfigurationStore.load() ?? ServerConfiguration.default
        let previousChatCfg = ChatConfigurationStore.load()

        var configuration = previousServerCfg
        configuration.port = port
        configuration.exposeToNetwork = tempExposeToNetwork
        configuration.startAtLogin = tempStartAtLogin
        configuration.hideDockIcon = tempHideDockIcon

        let defaults = ServerConfiguration.default
        let trimmedTopP = tempTopP.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTopP.isEmpty {
            configuration.genTopP = defaults.genTopP
        } else {
            configuration.genTopP = Float(trimmedTopP) ?? defaults.genTopP
        }

        let trimmedMaxKV = tempMaxKV.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.genMaxKVSize = trimmedMaxKV.isEmpty ? nil : Int(trimmedMaxKV)

        configuration.modelEvictionPolicy = tempEvictionPolicy

        // Cache engine overrides — empty / .auto → nil (auto-tune).
        // Stacks 2, 3, 4, 6 require a model reload to take effect.
        // Stacks 1 and 5 flow through GenerateParameters per-request and
        // take effect on the next generation — no reload needed.
        let trimmedPrefill = tempCachePrefillStepSize.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMaxBlocks = tempCacheMaxBlocks.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDiskGB = tempCacheDiskMaxGB.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAffineBits = tempCacheAffineBits.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAffineGroup = tempCacheAffineGroupSize.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTurboKey = tempCacheTurboKeyBits.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTurboValue = tempCacheTurboValueBits.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedQuantStart = tempCacheQuantStart.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSSM = tempCacheSSMMaxEntries.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.cacheConfig = ServerCacheConfig(
            prefillStepSize: trimmedPrefill.isEmpty ? nil : Int(trimmedPrefill),
            usePagedCache: tempCacheUsePaged.optionalBool,
            maxCacheBlocks: trimmedMaxBlocks.isEmpty ? nil : Int(trimmedMaxBlocks),
            pagedBlockSize: tempCachePagedBlockSize.optionalInt,
            enableDiskCache: tempCacheEnableDisk.optionalBool,
            diskCacheMaxGB: trimmedDiskGB.isEmpty ? nil : Float(trimmedDiskGB),
            kvQuantMode: tempCacheQuantMode.optionalMode,
            affineKVBits: trimmedAffineBits.isEmpty ? nil : Int(trimmedAffineBits),
            affineKVGroupSize: trimmedAffineGroup.isEmpty ? nil : Int(trimmedAffineGroup),
            turboKeyBits: trimmedTurboKey.isEmpty ? nil : Int(trimmedTurboKey),
            turboValueBits: trimmedTurboValue.isEmpty ? nil : Int(trimmedTurboValue),
            quantizedKVStart: trimmedQuantStart.isEmpty ? nil : Int(trimmedQuantStart),
            ssmMaxEntries: trimmedSSM.isEmpty ? nil : Int(trimmedSSM)
        )

        let parsedOrigins: [String] =
            tempAllowedOrigins
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        configuration.allowedOrigins = parsedOrigins

        let serverConfigChanged = previousServerCfg != configuration
        let startAtLoginChanged = previousServerCfg.startAtLogin != configuration.startAtLogin

        // `serverRestartNeeded` gates restarting the NIO HTTP server. Only the
        // fields that affect how the socket is opened / CORS / eviction belong
        // here. Generation-time settings (top-p, maxKV) flow into
        // `RuntimeConfig.snapshot()` and are re-read on the next request via
        // `ModelRuntime.invalidateConfig()` below — they do NOT require a NIO
        // restart nor a model reload.
        let serverRestartNeeded =
            previousServerCfg.port != configuration.port
            || previousServerCfg.exposeToNetwork != configuration.exposeToNetwork
            || previousServerCfg.allowedOrigins != configuration.allowedOrigins
            || previousServerCfg.modelEvictionPolicy != configuration.modelEvictionPolicy

        let runtimeConfigChanged =
            previousServerCfg.genTopP != configuration.genTopP
            || previousServerCfg.genMaxKVSize != configuration.genMaxKVSize

        do {
            try ServerConfigurationStore.saveThrowing(configuration)
        } catch {
            showSaveError("Failed to save server settings", error: error)
            return
        }

        let trimmedTemp = tempChatTemperature.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedTemp: Float? = {
            guard !trimmedTemp.isEmpty, let v = Float(trimmedTemp) else { return nil }
            return max(0.0, min(2.0, v))
        }()

        let trimmedMax = tempChatMaxTokens.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedMax: Int? = {
            guard !trimmedMax.isEmpty, let v = Int(trimmedMax) else { return nil }
            return max(1, v)
        }()

        let trimmedContext = tempChatContextLength.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedContext: Int? = {
            guard !trimmedContext.isEmpty, let v = Int(trimmedContext) else { return nil }
            return max(2048, v)
        }()

        let trimmedTopPChat = tempChatTopP.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedTopP: Float? = {
            guard !trimmedTopPChat.isEmpty, let v = Float(trimmedTopPChat) else { return nil }
            return max(0.0, min(1.0, v))
        }()

        let parsedMaxToolAttempts: Int? = {
            let s = tempChatMaxToolAttempts.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, let v = Int(s) else { return nil }
            return max(1, min(50, v))
        }()

        let parsedAgentTemp: Float? = {
            let s = tempAgentTemperature.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, let v = Float(s) else { return nil }
            return max(0.0, min(2.0, v))
        }()

        let parsedAgentMax: Int? = {
            let s = tempAgentMaxTokens.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, let v = Int(s) else { return nil }
            return max(1, v)
        }()

        let parsedAgentTopP: Float? = {
            let s = tempAgentTopP.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, let v = Float(s) else { return nil }
            return max(0.0, min(1.0, v))
        }()

        let parsedAgentMaxIterations: Int? = {
            let s = tempAgentMaxIterations.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, let v = Int(s) else { return nil }
            return max(1, min(100, v))
        }()

        let existingDefaultModel = previousChatCfg.defaultModel
        let chatCfg = ChatConfiguration(
            hotkey: tempChatHotkey,
            systemPrompt: tempSystemPrompt,
            temperature: parsedTemp,
            maxTokens: parsedMax,
            contextLength: parsedContext,
            topPOverride: parsedTopP,
            maxToolAttempts: parsedMaxToolAttempts,
            defaultModel: existingDefaultModel,
            coreModelProvider: tempCoreModelProvider.isEmpty ? nil : tempCoreModelProvider,
            coreModelName: tempCoreModelName.isEmpty ? nil : tempCoreModelName,
            workTemperature: parsedAgentTemp,
            workMaxTokens: parsedAgentMax,
            workTopPOverride: parsedAgentTopP,
            workMaxIterations: parsedAgentMaxIterations,
            preflightSearchMode: tempPreflightSearchMode,
            disableTools: tempDisableTools,
            showChatBarToolsChip: tempShowChatBarToolsChip,
            enableClipboardMonitoring: tempEnableClipboardMonitoring
        )
        // ChatConfigurationStore.saveThrowing() delegates to
        // AppConfiguration.shared.updateChatConfigThrowing() which updates
        // the @Published chatConfig AND posts .appConfigurationChanged on
        // successful write. On failure the in-memory cache is rolled back
        // to the previous value and the error bubbles up here so we can
        // toast. See 05-CONFIGURABILITY-AUDIT.md Issue 10 for why we care.
        do {
            try ChatConfigurationStore.saveThrowing(chatCfg)
        } catch {
            showSaveError("Failed to save chat settings", error: error)
            return
        }

        // If disableTools actually changed, every open session's preflight
        // cache is holding tool specs computed under the old flag. Bulk-
        // invalidate them so the next request in each session recomputes
        // with the new state. Uses the batch helper added in Phase A (M-03)
        // + the session enumerator from M-02.
        if previousChatCfg.disableTools != chatCfg.disableTools {
            let allSessionIds = ChatWindowManager.shared.allActiveSessionIds()
            PluginHostContext.invalidatePreflightCaches(
                sessionIds: allSessionIds.map { $0.uuidString }
            )
        }

        // Persist memory enable toggle. Budgets are not user-adjustable in
        // this UI — users can edit MemoryConfiguration.json directly for
        // advanced tuning.
        var memoryCfg = MemoryConfigurationStore.load()
        if memoryCfg.enabled != tempMemoryEnabled {
            memoryCfg.enabled = tempMemoryEnabled
            do {
                try MemoryConfigurationStore.saveThrowing(memoryCfg)
            } catch {
                showSaveError("Failed to save memory settings", error: error)
                return
            }
            // Drop the 10-second TTL cache so the next prompt reflects the new
            // enabled state immediately instead of waiting for entries to expire.
            Task { await MemoryContextAssembler.invalidateAll() }
        }

        let hotkeyChanged = previousChatCfg.hotkey != chatCfg.hotkey

        if hotkeyChanged {
            AppDelegate.shared?.applyChatHotkey()
        }
        if startAtLoginChanged {
            LoginItemService.shared.applyStartAtLogin(configuration.startAtLogin)
        }

        Task { @MainActor in
            if serverConfigChanged {
                AppDelegate.shared?.serverController.configuration = configuration
            }
            if serverRestartNeeded {
                await AppDelegate.shared?.serverController.restartServer()
            }
            if runtimeConfigChanged {
                // Drop the cached RuntimeConfig snapshot so the next
                // generation re-reads fresh values from ServerConfiguration.
                await ModelRuntime.shared.invalidateConfig()
            }
        }

        showSuccess("Settings saved successfully")
    }

    // MARK: - Cache Engine Subsection

    /// The 6-stack cache engine settings subsection. Every control
    /// defaults to "Auto" which forwards `nil` into `ServerCacheConfig`.
    /// Where vmlx's package default differs from osaurus's preferred
    /// default (notably the KV quant mode, where vmlx defaults to `.none`
    /// but osaurus ships with TurboQuant), `ModelRuntime.makeGenerateParameters`
    /// substitutes the osaurus preference on the nil case.
    ///
    /// **Hot-reload behavior differs by stack**:
    /// - Stacks 1 (prefill) and 5 (quantization) flow through
    ///   `GenerateParameters` per-request — take effect on the next
    ///   generation with no model reload.
    /// - Stacks 2, 3, 4, 6 flow through `CacheCoordinatorConfig` which
    ///   is immutable after construction — require a model reload.
    @ViewBuilder
    private var cacheEngineSubsection: some View {
        SettingsSubsection(label: "Cache Engine") {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    "Tune the 6-stack KV cache engine. Every control defaults to Auto — osaurus ships with TurboQuant enabled and sensible RAM-scaled defaults. Stacks 1 and 5 take effect on next generation; stacks 2, 3, 4, 6 take effect on next model load.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)

                // Disk cache usage readout + clear button (Stack 4 status)
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                    Text("Disk cache: \(formatBytes(diskCacheUsageBytes))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                    Button {
                        _ = OsaurusPaths.clearDiskKVCache()
                        diskCacheUsageBytes = OsaurusPaths.diskKVCacheUsageBytes()
                        showSuccess("Disk cache cleared")
                    } label: {
                        Text("Clear", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(diskCacheUsageBytes == 0)
                }

                SettingsDivider()

                // Stack 2: Prefix caching toggle
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prefix Caching (L1)", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                    Picker("", selection: $tempCacheUsePaged) {
                        ForEach(CacheTriState.allCases) { state in
                            Text(state.rawValue).tag(state)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(
                        "Paged L1 cache for prompt prefix reuse. Disabling is rarely useful — this is the main TTFT win.",
                        bundle: .module
                    )
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                }

                // Stack 2+3: Max cache blocks
                SettingsStepperField(
                    label: "Cache Block Pool",
                    help: "Max number of paged blocks in the L1 pool. Leave blank for Auto (RAM-scaled: 500 / 1000 / 2000 for <16GB / 16–48GB / >48GB).",
                    text: $tempCacheMaxBlocks,
                    range: 100 ... 4000,
                    step: 100,
                    defaultValue: 1000
                )

                // Stack 3: Paged block size picker
                VStack(alignment: .leading, spacing: 4) {
                    Text("Block Size (tokens)", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                    Picker("", selection: $tempCachePagedBlockSize) {
                        ForEach(CachePagedBlockSizeChoice.allCases) { size in
                            Text(size.rawValue).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(
                        "Tokens per block. Smaller = finer reuse + more metadata; larger = coarser reuse. Auto = 64.",
                        bundle: .module
                    )
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                }

                SettingsDivider()

                // Stack 4: Disk cache toggle
                VStack(alignment: .leading, spacing: 4) {
                    Text("Disk KV Cache (L2)", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                    Picker("", selection: $tempCacheEnableDisk) {
                        ForEach(CacheTriState.allCases) { state in
                            Text(state.rawValue).tag(state)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(
                        "Persist cached KV state to local SSD for cross-session reuse. Auto = enabled when the cache dir is writable.",
                        bundle: .module
                    )
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                }

                // Stack 4: Disk cache max size
                SettingsSliderField(
                    label: "Disk Cache Budget (GB)",
                    help: "Max disk cache size. Leave blank for Auto (4.0 GB).",
                    text: $tempCacheDiskMaxGB,
                    range: 1 ... 50,
                    step: 0.5,
                    defaultValue: 4.0,
                    formatString: "%.1f"
                )

                SettingsDivider()

                // Stack 6: SSM companion cache
                SettingsStepperField(
                    label: "SSM Companion Cache",
                    help: "Max entries in the state-space model companion cache (only active on hybrid models like Mamba). Leave blank for Auto (50).",
                    text: $tempCacheSSMMaxEntries,
                    range: 10 ... 500,
                    step: 10,
                    defaultValue: 50
                )

                SettingsDivider()

                // Stack 1: Continuous batching prefill step
                SettingsStepperField(
                    label: "Prefill Step Size (tokens)",
                    help: "Number of tokens per prefill chunk during prompt processing. Smaller = lower peak memory on small machines, slightly slower prefill. Larger = faster prefill on high-RAM machines. Leave blank for Auto (512).",
                    text: $tempCachePrefillStepSize,
                    range: 64 ... 4096,
                    step: 64,
                    defaultValue: 512
                )

                SettingsDivider()

                // Stack 5: KV quantization mode picker
                VStack(alignment: .leading, spacing: 4) {
                    Text("KV Quantization Mode", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                    Picker("", selection: $tempCacheQuantMode) {
                        ForEach(CacheQuantModeChoice.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(
                        "Auto uses TurboQuant(3,3) — osaurus's preferred default for ~26× KV compression with minimal quality loss. Off disables quantization entirely. Affine and TurboQuant expose their tuning knobs below.",
                        bundle: .module
                    )
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                }

                // Affine mode knobs — only meaningful when mode == .affine
                if tempCacheQuantMode == .affine {
                    SettingsStepperField(
                        label: "Affine Bits",
                        help: "Bits per element for affine quantization. Lower = more compression, more quality loss. Typical: 2, 4, 8. Leave blank for Auto (4).",
                        text: $tempCacheAffineBits,
                        range: 2 ... 8,
                        step: 1,
                        defaultValue: 4
                    )
                    SettingsStepperField(
                        label: "Affine Group Size",
                        help: "Group size for affine quantization. Leave blank for Auto (64).",
                        text: $tempCacheAffineGroupSize,
                        range: 16 ... 256,
                        step: 16,
                        defaultValue: 64
                    )
                }

                // TurboQuant mode knobs — meaningful when mode == .turboQuant
                // OR when mode == .auto (since Auto is TurboQuant).
                if tempCacheQuantMode == .turboQuant || tempCacheQuantMode == .auto {
                    SettingsStepperField(
                        label: "TurboQuant Key Bits",
                        help: "Bits per key element. Lower = more compression, more quality loss. Leave blank for Auto (3).",
                        text: $tempCacheTurboKeyBits,
                        range: 2 ... 8,
                        step: 1,
                        defaultValue: 3
                    )
                    SettingsStepperField(
                        label: "TurboQuant Value Bits",
                        help: "Bits per value element. Leave blank for Auto (3).",
                        text: $tempCacheTurboValueBits,
                        range: 2 ... 8,
                        step: 1,
                        defaultValue: 3
                    )
                }

                // Quantized start threshold — meaningful for all non-.off modes
                if tempCacheQuantMode != .off {
                    SettingsStepperField(
                        label: "Quantize After N Tokens",
                        help: "Tokens before this offset stay full-precision. Use a non-zero value to preserve short prompts while quantizing long contexts. Leave blank for Auto (0 — quantize immediately).",
                        text: $tempCacheQuantStart,
                        range: 0 ... 8192,
                        step: 64,
                        defaultValue: 0
                    )
                }
            }
        }
    }

    /// Format a byte count for the disk cache readout. Keeps the label
    /// short (e.g. "1.2 GB", "340 MB") rather than spelling out full
    /// decimal figures.
    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - Core Model Picker

    private var coreModelIdentifierBinding: Binding<String> {
        Binding(
            get: {
                if tempCoreModelName.isEmpty { return "" }
                return tempCoreModelProvider.isEmpty
                    ? tempCoreModelName
                    : "\(tempCoreModelProvider)/\(tempCoreModelName)"
            },
            set: { newValue in
                if newValue.isEmpty {
                    tempCoreModelProvider = ""
                    tempCoreModelName = ""
                    return
                }
                let parts = newValue.split(separator: "/", maxSplits: 1)
                if parts.count == 2 {
                    tempCoreModelProvider = String(parts[0])
                    tempCoreModelName = String(parts[1])
                } else {
                    tempCoreModelProvider = ""
                    tempCoreModelName = newValue
                }
            }
        )
    }

    private var coreModelPicker: some View {
        Picker("", selection: coreModelIdentifierBinding) {
            Text("None", bundle: .module).tag("")
            if !coreModelIdentifierBinding.wrappedValue.isEmpty,
                !coreModelPickerItems.contains(where: { $0.id == coreModelIdentifierBinding.wrappedValue })
            {
                Text(coreModelIdentifierBinding.wrappedValue)
                    .tag(coreModelIdentifierBinding.wrappedValue)
            }
            ForEach(coreModelPickerItems) { option in
                Text(option.displayName)
                    .tag(option.id)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 280)
    }
}

// MARK: - CLI Install Helper
extension ConfigurationView {
    private func installCLI() {
        let fm = FileManager.default

        guard let cliURL = resolveCLIExecutableURL() else {
            cliInstallSuccess = false
            cliInstallMessage = "CLI not found. Build the app with 'make app' or install via release DMG."
            return
        }

        // Candidate target directories
        let brewBin = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)
        let usrLocalBin = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        let userLocalBin = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)

        if tryInstall(cliURL: cliURL, into: brewBin) {
            cliInstallSuccess = true
            cliInstallMessage = "Installed to \(brewBin.appendingPathComponent("osaurus").path)"
            return
        }

        if tryInstall(cliURL: cliURL, into: usrLocalBin) {
            cliInstallSuccess = true
            cliInstallMessage = "Installed to \(usrLocalBin.appendingPathComponent("osaurus").path)"
            return
        }

        // Fallback to user-local bin
        do {
            try fm.createDirectory(at: userLocalBin, withIntermediateDirectories: true)
        } catch {
            cliInstallSuccess = false
            cliInstallMessage = "Failed to prepare ~/.local/bin (\(error.localizedDescription))"
            return
        }

        if tryInstall(cliURL: cliURL, into: userLocalBin) {
            let linkPath = userLocalBin.appendingPathComponent("osaurus").path
            let inPath = isDirInPATH(userLocalBin.path)
            cliInstallSuccess = true
            cliInstallMessage =
                inPath
                ? "Installed to \(linkPath)"
                : "Installed to \(linkPath). Add to PATH."
            return
        }

        cliInstallSuccess = false
        cliInstallMessage = "Installation failed. Try: scripts/install_cli_symlink.sh"
    }

    private func resolveCLIExecutableURL() -> URL? {
        let fm = FileManager.default
        let appURL = Bundle.main.bundleURL

        // 1. Prefer embedded CLI in Helpers (production build via 'make app')
        let helpers = appURL.appendingPathComponent("Contents/Helpers/osaurus", isDirectory: false)
        if fm.fileExists(atPath: helpers.path), fm.isExecutableFile(atPath: helpers.path) {
            return helpers
        }

        // 2. Try MacOS folder (legacy or alternative embedding)
        let macOS = appURL.appendingPathComponent("Contents/MacOS/osaurus", isDirectory: false)
        if fm.fileExists(atPath: macOS.path), fm.isExecutableFile(atPath: macOS.path) {
            return macOS
        }

        // 3. Development: try the build Products directory
        let productsDir = appURL.deletingLastPathComponent()

        // Check for osaurus-cli binary (the actual CLI product name)
        let debugCLI = productsDir.appendingPathComponent("osaurus-cli", isDirectory: false)
        if fm.fileExists(atPath: debugCLI.path), fm.isExecutableFile(atPath: debugCLI.path) {
            return debugCLI
        }

        // Check for osaurus binary in Products (might be named this in some builds)
        let debugOsaurus = productsDir.appendingPathComponent("osaurus", isDirectory: false)
        if fm.fileExists(atPath: debugOsaurus.path), fm.isExecutableFile(atPath: debugOsaurus.path) {
            return debugOsaurus
        }

        // Check Release folder
        let releaseDir = productsDir.deletingLastPathComponent().appendingPathComponent("Release")
        let releaseCLI = releaseDir.appendingPathComponent("osaurus-cli", isDirectory: false)
        if fm.fileExists(atPath: releaseCLI.path), fm.isExecutableFile(atPath: releaseCLI.path) {
            return releaseCLI
        }

        let releaseOsaurus = releaseDir.appendingPathComponent("osaurus", isDirectory: false)
        if fm.fileExists(atPath: releaseOsaurus.path), fm.isExecutableFile(atPath: releaseOsaurus.path) {
            return releaseOsaurus
        }

        // 4. Check inside Release app bundle's Helpers folder
        let releaseAppHelpers =
            releaseDir
            .appendingPathComponent("osaurus.app/Contents/Helpers/osaurus", isDirectory: false)
        if fm.fileExists(atPath: releaseAppHelpers.path), fm.isExecutableFile(atPath: releaseAppHelpers.path) {
            return releaseAppHelpers
        }

        // 5. Check inside Release app bundle's MacOS folder
        let releaseAppMacOS =
            releaseDir
            .appendingPathComponent("osaurus.app/Contents/MacOS/osaurus", isDirectory: false)
        if fm.fileExists(atPath: releaseAppMacOS.path), fm.isExecutableFile(atPath: releaseAppMacOS.path) {
            return releaseAppMacOS
        }

        return nil
    }

    private func tryInstall(cliURL: URL, into dir: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }

        let linkURL = dir.appendingPathComponent("osaurus")

        // If an entry exists, replace only if it's a symlink
        if fm.fileExists(atPath: linkURL.path) {
            do {
                _ = try fm.destinationOfSymbolicLink(atPath: linkURL.path)
                // It's a symlink – remove and replace
                try? fm.removeItem(at: linkURL)
            } catch {
                // Not a symlink (likely a real file); do not overwrite
                return false
            }
        }

        do {
            try fm.createSymbolicLink(atPath: linkURL.path, withDestinationPath: cliURL.path)
            return true
        } catch {
            return false
        }
    }

    private func isDirInPATH(_ dir: String) -> Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").map(String.init).contains { $0 == dir }
    }
}

// MARK: - Toast Configuration Helpers
extension ConfigurationView {
    private func saveToastConfig() {
        let defaults = ToastConfiguration.default

        let trimmedTimeout = tempToastTimeout.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedTimeout: TimeInterval = {
            guard !trimmedTimeout.isEmpty, let v = Double(trimmedTimeout) else {
                return defaults.defaultTimeout
            }
            return max(1.0, min(30.0, v))
        }()

        let trimmedMaxVisible = tempToastMaxVisible.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedMaxVisible: Int = {
            guard !trimmedMaxVisible.isEmpty, let v = Int(trimmedMaxVisible) else {
                return defaults.maxVisibleToasts
            }
            return max(1, min(10, v))
        }()

        let trimmedMaxConcurrent = tempToastMaxConcurrent.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedMaxConcurrent: Int = {
            guard !trimmedMaxConcurrent.isEmpty, let v = Int(trimmedMaxConcurrent) else {
                return defaults.maxConcurrentTasks
            }
            return max(1, min(50, v))
        }()

        let config = ToastConfiguration(
            position: tempToastPosition,
            defaultTimeout: parsedTimeout,
            maxVisibleToasts: parsedMaxVisible,
            groupByAgent: true,
            enabled: tempToastEnabled,
            maxConcurrentTasks: parsedMaxConcurrent
        )

        ToastManager.shared.updateConfiguration(config)
    }

    private func showTestToast() {
        ToastManager.shared.success(
            "Test Notification",
            message: "Toast notifications are working!"
        )
    }
}

// MARK: - Toast Position Picker

private struct ToastPositionPicker: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Binding var selection: ToastPosition

    @State private var isHovered = false

    var body: some View {
        Menu {
            ForEach(ToastPosition.allCases, id: \.self) { position in
                Button(action: { selection = position }) {
                    HStack {
                        Text(position.displayName)
                        if selection == position {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: positionIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.accentColor)

                Text(selection.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.primaryText)

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isHovered
                                    ? themeManager.currentTheme.accentColor.opacity(0.5)
                                    : themeManager.currentTheme.inputBorder,
                                lineWidth: isHovered ? 1.5 : 1
                            )
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private var positionIcon: String {
        switch selection {
        case .topRight, .topLeft, .topCenter:
            return "arrow.up.square"
        case .bottomRight, .bottomLeft, .bottomCenter:
            return "arrow.down.square"
        }
    }
}

// MARK: - Reusable Settings Components

private struct SettingsSection<Content: View>: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header with icon and uppercase title
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.accentColor)

                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(themeManager.currentTheme.secondaryText)
                    .tracking(0.5)
            }

            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(themeManager.currentTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(themeManager.currentTheme.cardBorder, lineWidth: 1)
                )
        )
    }
}

private struct SettingsField<Content: View>: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    var hint: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(themeManager.currentTheme.secondaryText)

            content()

            if let hint = hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
            }
        }
    }
}

private struct SettingsSubsection<Content: View>: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Subsection header
            HStack(spacing: 6) {
                Rectangle()
                    .fill(themeManager.currentTheme.accentColor)
                    .frame(width: 3, height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))

                Text(label.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .tracking(0.5)
            }

            content()
                .padding(.leading, 9)
        }
    }
}

// MARK: - Styled Settings Text Area

private struct StyledSettingsTextArea: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    @Binding var text: String
    let placeholder: String
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(themeManager.currentTheme.secondaryText)

            ZStack(alignment: .topLeading) {
                // Themed placeholder overlay
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.placeholderText)
                        .padding(.top, 12)
                        .padding(.leading, 12)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 100, maxHeight: 160)
                    .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                    )
            )

            Text(hint)
                .font(.system(size: 11))
                .foregroundColor(themeManager.currentTheme.tertiaryText)
        }
    }
}

// MARK: - Styled Settings Text Field

private struct StyledSettingsTextField: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    @Binding var text: String
    let placeholder: String
    let help: String

    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.secondaryText)

                Spacer()

                Text(help)
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    // Themed placeholder overlay
                    if text.isEmpty && !placeholder.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(themeManager.currentTheme.placeholderText)
                            .allowsHitTesting(false)
                    }

                    TextField(
                        "",
                        text: $text,
                        onEditingChanged: { editing in
                            withAnimation(.easeOut(duration: 0.15)) {
                                isFocused = editing
                            }
                        }
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isFocused
                                    ? themeManager.currentTheme.accentColor.opacity(0.5)
                                    : themeManager.currentTheme.inputBorder,
                                lineWidth: isFocused ? 1.5 : 1
                            )
                    )
            )
        }
    }
}

// MARK: - Settings Slider Field

private struct SettingsSliderField: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    let help: String
    @Binding var text: String
    let range: ClosedRange<Float>
    let step: Float
    let defaultValue: Float
    let formatString: String

    @State private var sliderValue: Float = 0
    @State private var isInitialized = false

    private var effectiveValue: Float {
        if let v = Float(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return min(max(v, range.lowerBound), range.upperBound)
        }
        return defaultValue
    }

    private var displayValue: String {
        String(format: formatString, effectiveValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.secondaryText)

                Spacer()

                Text(help)
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .lineLimit(1)
            }

            HStack(spacing: 12) {
                Text(String(format: formatString, range.lowerBound))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .frame(width: 28, alignment: .trailing)

                Slider(
                    value: $sliderValue,
                    in: range,
                    step: step
                )
                .tint(themeManager.currentTheme.accentColor)
                .onChange(of: sliderValue) { _, newValue in
                    guard isInitialized else { return }
                    text = String(format: formatString, newValue)
                }

                Text(String(format: formatString, range.upperBound))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .frame(width: 28, alignment: .leading)

                // Current value badge
                Text(displayValue)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(themeManager.currentTheme.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                            )
                    )
                    .frame(width: 52)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                    )
            )
        }
        .onAppear {
            sliderValue = effectiveValue
            DispatchQueue.main.async {
                isInitialized = true
            }
        }
        .onChange(of: text) { _, _ in
            guard isInitialized else { return }
            let newEffective = effectiveValue
            if abs(sliderValue - newEffective) > step / 2 {
                sliderValue = newEffective
            }
        }
    }
}

// MARK: - Settings Stepper Field

private struct SettingsStepperField: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    let help: String
    @Binding var text: String
    let range: ClosedRange<Int>
    let step: Int
    let defaultValue: Int

    @State private var isFocused = false

    private var effectiveValue: Int {
        if let v = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return min(max(v, range.lowerBound), range.upperBound)
        }
        return defaultValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.secondaryText)

                Spacer()

                Text(help)
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .lineLimit(1)
            }

            HStack(spacing: 0) {
                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text(String(defaultValue))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(themeManager.currentTheme.placeholderText)
                            .allowsHitTesting(false)
                    }

                    TextField(
                        "",
                        text: $text,
                        onEditingChanged: { editing in
                            withAnimation(.easeOut(duration: 0.15)) {
                                isFocused = editing
                            }
                        }
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                }
                .padding(.horizontal, 12)

                Divider()
                    .frame(height: 20)

                // Stepper buttons
                HStack(spacing: 0) {
                    Button(action: decrement) {
                        Image(systemName: "minus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(
                                effectiveValue <= range.lowerBound
                                    ? themeManager.currentTheme.tertiaryText
                                    : themeManager.currentTheme.primaryText
                            )
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(effectiveValue <= range.lowerBound)

                    Divider()
                        .frame(height: 20)

                    Button(action: increment) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(
                                effectiveValue >= range.upperBound
                                    ? themeManager.currentTheme.tertiaryText
                                    : themeManager.currentTheme.primaryText
                            )
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(effectiveValue >= range.upperBound)
                }
            }
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isFocused
                                    ? themeManager.currentTheme.accentColor.opacity(0.5)
                                    : themeManager.currentTheme.inputBorder,
                                lineWidth: isFocused ? 1.5 : 1
                            )
                    )
            )
        }
    }

    private func increment() {
        let newValue = min(effectiveValue + step, range.upperBound)
        text = String(newValue)
    }

    private func decrement() {
        let newValue = max(effectiveValue - step, range.lowerBound)
        text = String(newValue)
    }
}

private struct SettingsToggle: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let title: String
    let description: String
    var badge: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(themeManager.currentTheme.primaryText)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(themeManager.currentTheme.accentColor)
                    }
                }
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(themeManager.currentTheme.tertiaryText)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(SwitchToggleStyle(tint: themeManager.currentTheme.accentColor))
                .labelsHidden()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(themeManager.currentTheme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                )
        )
    }
}

private struct SettingsDivider: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        Rectangle()
            .fill(themeManager.currentTheme.cardBorder)
            .frame(height: 1)
    }
}

private struct SettingsButtonStyle: ButtonStyle {
    @ObservedObject private var themeManager = ThemeManager.shared
    let isPrimary: Bool
    let isDestructive: Bool

    init(isPrimary: Bool = false, isDestructive: Bool = false) {
        self.isPrimary = isPrimary
        self.isDestructive = isDestructive
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(
                isDestructive
                    ? .red
                    : (isPrimary ? .white : themeManager.currentTheme.primaryText)
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isPrimary ? themeManager.currentTheme.accentColor : themeManager.currentTheme.tertiaryBackground
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isPrimary ? Color.clear : themeManager.currentTheme.inputBorder, lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

// MARK: - Voice Settings Section

private struct VoiceSettingsSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var modelManager = SpeechModelManager.shared
    @ObservedObject private var speechService = SpeechService.shared

    var body: some View {
        SettingsSection(title: "Voice (Advanced)", icon: "waveform") {
            VStack(alignment: .leading, spacing: 20) {
                Text("Configure voice settings directly in the Voice tab.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(themeManager.currentTheme.secondaryText)

                // Status info
                HStack(spacing: 12) {
                    // Model status
                    HStack(spacing: 6) {
                        if speechService.isLoadingModel {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 8, height: 8)
                        } else {
                            Circle()
                                .fill(
                                    speechService.isModelLoaded
                                        ? themeManager.currentTheme.successColor
                                        : themeManager.currentTheme.tertiaryText
                                )
                                .frame(width: 8, height: 8)
                        }
                        Text(modelStatusText)
                            .font(.system(size: 11))
                            .foregroundColor(themeManager.currentTheme.secondaryText)
                    }

                    Spacer()

                    // Quick link to Voice tab
                    Button(action: {
                        AppDelegate.shared?.showManagementWindow(initialTab: .voice)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.circle")
                                .font(.system(size: 11))
                            Text("Open Voice Tab", bundle: .module)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(themeManager.currentTheme.accentColor)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(themeManager.currentTheme.tertiaryBackground)
                )
            }
        }
    }

    private var modelStatusText: String {
        if speechService.isLoadingModel {
            return "Loading model..."
        } else if speechService.isModelLoaded {
            if let modelId = speechService.loadedModelId,
                let model = modelManager.availableModels.first(where: { $0.id == modelId })
            {
                return model.name
            }
            return "Model Loaded"
        } else if modelManager.downloadedModelsCount == 0 {
            return "No models downloaded"
        } else {
            return "Model not loaded"
        }
    }

}

// MARK: - Work Settings Section

private struct AgentSettingsSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var refreshId = UUID()

    @Binding var workTemperature: String
    @Binding var workMaxTokens: String
    @Binding var agentTopP: String
    @Binding var workMaxIterations: String

    // (name, display, desc, destructive, defaultPolicy)
    private static let folderTools:
        [(name: String, display: String, desc: String, destructive: Bool, defaultPolicy: ToolPermissionPolicy)] = [
            ("file_write", "Write Files", "Create and modify files", false, .auto),
            ("file_move", "Move Files", "Move files and directories", false, .auto),
            ("file_copy", "Copy Files", "Copy files and directories", false, .auto),
            ("file_delete", "Delete Files", "Delete files and directories", true, .ask),
            ("dir_create", "Create Directories", "Create new directories", false, .auto),
            ("file_edit", "Edit Files", "Edit file content with search/replace", false, .auto),
            ("shell_run", "Run Shell Commands", "Execute shell commands in the folder", true, .ask),
            ("git_commit", "Git Commit", "Commit changes to git repository", true, .ask),
            ("batch", "Batch Operations", "Execute multiple tool operations in sequence", false, .ask),
        ]

    var body: some View {
        SettingsSection(title: "Work", icon: "cpu") {
            VStack(alignment: .leading, spacing: 16) {
                // Generation Settings
                SettingsSubsection(label: "Generation") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(
                            "Controls how the AI reasons and calls tools. Lower temperature improves reliability.",
                            bundle: .module
                        )
                        .font(.system(size: 12))
                        .foregroundColor(themeManager.currentTheme.secondaryText)

                        SettingsSliderField(
                            label: "Temperature",
                            help: "Lower = more reliable tool use",
                            text: $workTemperature,
                            range: 0 ... 2,
                            step: 0.1,
                            defaultValue: 0.3,
                            formatString: "%.1f"
                        )
                        SettingsStepperField(
                            label: "Max Tokens",
                            help: "Tokens per work iteration",
                            text: $workMaxTokens,
                            range: 1 ... 65536,
                            step: 512,
                            defaultValue: 4096
                        )
                        SettingsSliderField(
                            label: "Top P Override",
                            help: "Sampling diversity (0–1)",
                            text: $agentTopP,
                            range: 0 ... 1,
                            step: 0.05,
                            defaultValue: 1.0,
                            formatString: "%.2f"
                        )
                        SettingsStepperField(
                            label: "Max Iterations",
                            help: "Max reasoning loop iterations",
                            text: $workMaxIterations,
                            range: 1 ... 100,
                            step: 5,
                            defaultValue: 50
                        )
                    }
                }

                SettingsDivider()

                // Permissions
                SettingsSubsection(label: "Permissions") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(
                            "Control how work folder tools execute when working with folders in Work mode.",
                            bundle: .module
                        )
                        .font(.system(size: 12))
                        .foregroundColor(themeManager.currentTheme.secondaryText)

                        VStack(spacing: 0) {
                            ForEach(Self.folderTools, id: \.name) { tool in
                                AgentToolPermissionRow(
                                    name: tool.name,
                                    displayName: tool.display,
                                    description: tool.desc,
                                    isDestructive: tool.destructive,
                                    defaultPolicy: tool.defaultPolicy,
                                    onPolicyChange: { refreshId = UUID() }
                                )
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(themeManager.currentTheme.inputBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                                )
                        )
                        .id(refreshId)

                        HStack {
                            Spacer()
                            Button(action: resetAllToDefault) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.system(size: 11))
                                    Text("Reset All to Default", bundle: .module)
                                        .font(.system(size: 12, weight: .medium))
                                }
                            }
                            .buttonStyle(SettingsButtonStyle())
                            .help(Text("Reset all work tool permissions to default", bundle: .module))
                        }
                    }
                }
            }
        }
    }

    private func resetAllToDefault() {
        for tool in Self.folderTools {
            ToolRegistry.shared.clearPolicy(for: tool.name)
        }
        refreshId = UUID()
    }
}

// MARK: - Work Tool Permission Row

private struct AgentToolPermissionRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var isHovered = false

    let name: String
    let displayName: String
    let description: String
    let isDestructive: Bool
    let defaultPolicy: ToolPermissionPolicy
    let onPolicyChange: () -> Void

    /// Returns the configured policy, or nil if using default
    private var configuredPolicy: ToolPermissionPolicy? {
        ToolConfigurationStore.load().policy[name]
    }

    /// Returns the effective policy (configured or default)
    private var effectivePolicy: ToolPermissionPolicy {
        configuredPolicy ?? defaultPolicy
    }

    var body: some View {
        HStack(spacing: 12) {
            if isDestructive {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.currentTheme.warningColor)
                    .frame(width: 16)
            } else {
                Color.clear.frame(width: 16)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                Text(description)
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
            }

            Spacer()

            Picker(
                "",
                selection: Binding(
                    get: { effectivePolicy },
                    set: { newValue in
                        ToolRegistry.shared.setPolicy(newValue, for: name)
                        onPolicyChange()
                    }
                )
            ) {
                Text("Auto", bundle: .module).tag(ToolPermissionPolicy.auto)
                Text("Ask", bundle: .module).tag(ToolPermissionPolicy.ask)
                Text("Deny", bundle: .module).tag(ToolPermissionPolicy.deny)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isHovered ? themeManager.currentTheme.tertiaryBackground.opacity(0.5) : Color.clear)
        .onHover { isHovered = $0 }
    }
}
