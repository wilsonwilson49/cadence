import SwiftUI
import ServiceManagement
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var google: GoogleCalendar
    @EnvironmentObject private var engine: ReminderEngine
    @EnvironmentObject private var sync: SyncService
    @EnvironmentObject private var calendly: CalendlyService
    @EnvironmentObject private var importer: CalendarImporter
    @State private var calendlyToken = ""
    @State private var syncPassword = ""

    @State private var authStatus: UNAuthorizationStatus = .notDetermined
    @State private var loginItemOn = SMAppService.mainApp.status == .enabled
    @State private var runInBackground = WindowManager.runsInBackground
    @State private var loginError: String?
    @State private var showSecret = false
    @AppStorage(AppearanceMode.key) private var appearance = AppearanceMode.dark.rawValue
    @AppStorage(AppFont.key) private var fontFamily = AppFont.defaultFamily
    @State private var newSite = ""
    @State private var newApp = ""

    var body: some View {
        Form {
            appearanceSection
            syncSection
            notificationsSection
            ringSection
            sidebarSection
            nudgeSection
            toughLoveSection
            checkInSection
            reflectionSection
            startupSection
            googleSection
            calendlySection
            importSection
            presetsSection
            availabilitySection
            dataSection
        }
        .formStyle(.grouped)
        .task { authStatus = await Notifier.shared.authorizationStatus() }
    }

    // MARK: Sections

    private var appearanceSection: some View {
        Section {
            Picker("Theme", selection: $appearance) { ForEach(AppearanceMode.allCases) { Text($0.title).tag($0.rawValue) } }
                .onChange(of: appearance) { _, v in (AppearanceMode(rawValue: v) ?? .dark).apply() }
            HStack {
                Picker("Font", selection: $fontFamily) {
                    ForEach(AppFont.presets, id: \.family) { p in Text(p.label).tag(p.family) }
                    if !AppFont.presets.contains(where: { $0.family == fontFamily }) { Text(fontFamily).tag(fontFamily) }
                }
                Menu("More fonts") {
                    ForEach(NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }, id: \.self) { f in
                        Button(f) { fontFamily = f }
                    }
                }
                .fixedSize()
            }
            .onChange(of: fontFamily) { _, _ in AppIconArt.applyToDock() }
            Text("The quick brown fox jumps over the lazy dog. 0123456789").font(.app(.body)).foregroundStyle(.secondary).id(fontFamily)
        } header: { Text("Appearance") } footer: { Text("This Mac only. Dark and Verdana are the defaults. The Dock icon's C follows the font while Cadence is running.") }
    }

    private static let siteSuggestions = ["youtube.com", "instagram.com", "tiktok.com", "reddit.com", "x.com", "facebook.com", "netflix.com", "twitch.tv"]

    private func addSite(_ raw: String) {
        var d = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let host = URL(string: d.contains("://") ? d : "https://" + d)?.host { d = host }
        if d.hasPrefix("www.") { d = String(d.dropFirst(4)) }
        guard !d.isEmpty, d.contains("."), !store.settings.blockedSites.contains(d) else { return }
        store.settings.blockedSites.append(d)
    }

    /// For people who put things off: what gets blocked, and when.
    private var toughLoveSection: some View {
        Section {
            Toggle("Block distracting apps and sites during focus and study sessions", isOn: $store.settings.blockDuringFocus)
            VStack(alignment: .leading, spacing: 6) {
                Text("Distracting apps").font(.app(.callout).weight(.medium))
                FlowRow(store.settings.distractingApps.map { app in
                    AnyView(HStack(spacing: 3) {
                        Text(app)
                        Button { store.settings.distractingApps.removeAll { $0 == app } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }.font(.app(.callout)).padding(.horizontal, 8).padding(.vertical, 2)
                     .background(RoundedRectangle(cornerRadius: 3).fill(Color.red.opacity(0.12))))
                })
                HStack {
                    TextField("App name, e.g. Discord", text: $newApp).onSubmit(addApp)
                    Button("Add", action: addApp).disabled(newApp.trimmingCharacters(in: .whitespaces).isEmpty)
                    Menu("Running apps") {
                        ForEach(runningApps, id: \.self) { n in Button(n) { newApp = n; addApp() } }
                    }.fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Blocked websites").font(.app(.callout).weight(.medium))
                FlowRow(store.settings.blockedSites.map { site in
                    AnyView(HStack(spacing: 3) {
                        Text(site)
                        Button { store.settings.blockedSites.removeAll { $0 == site } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }.font(.app(.callout)).padding(.horizontal, 8).padding(.vertical, 2)
                     .background(RoundedRectangle(cornerRadius: 3).fill(Color.red.opacity(0.12))))
                })
                HStack {
                    TextField("Website, e.g. youtube.com", text: $newSite).onSubmit { addSite(newSite); newSite = "" }
                    Button("Add") { addSite(newSite); newSite = "" }.disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
                    Menu("Suggestions") {
                        ForEach(Self.siteSuggestions.filter { !store.settings.blockedSites.contains($0) }, id: \.self) { d in Button(d) { addSite(d) } }
                    }.fixedSize()
                }
            }
            HStack {
                Button("Try blocking for a minute") { model.nag.blocker.testUntil = Date().addingTimeInterval(60) }
                Button("Preview a pushy pop-up") { model.nag.preview(.pushy) }
                Button("Preview the strict cover") { model.nag.preview(.strict) }
            }
        } header: { Text("Tough love") } footer: {
            Text("A task set to Strict (in its editor, under “For things you'd rather put off”) blocks these until it's checked off. Blocked apps are hidden as soon as they come to the front. Websites are blocked in Safari, Chrome, Arc, Brave, Edge, Vivaldi and Opera (not Firefox); the first time, macOS asks whether Cadence may control the browser.")
        }
    }

    private var runningApps: [String] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)
            .filter { n in n != "Cadence" && !store.settings.distractingApps.contains { $0.lowercased() == n.lowercased() } }.sorted()
    }

    private func addApp() {
        let a = newApp.trimmingCharacters(in: .whitespacesAndNewlines)
        newApp = ""
        guard !a.isEmpty, !store.settings.distractingApps.contains(where: { $0.lowercased() == a.lowercased() }) else { return }
        store.settings.distractingApps.append(a)
    }

    private var syncSection: some View {
        Section {
            if let user = sync.username {
                HStack {
                    Label("Signed in as \(user)", systemImage: "person.crop.circle.badge.checkmark").foregroundStyle(.green)
                    Spacer()
                    SyncIndicator(prominent: true)
                    Button("Sign out", role: .destructive) { sync.signOut() }
                }
            } else {
                TextField("Username", text: $sync.draftUsername).multilineTextAlignment(.leading)
                SecureField("Password", text: $syncPassword).multilineTextAlignment(.leading)
                HStack {
                    if sync.isSigningIn { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Create account") {
                        Task { await sync.signIn(username: sync.draftUsername, password: syncPassword, create: true); if sync.isSignedIn { syncPassword = "" } }
                    }
                    Button("Sign in") {
                        Task { await sync.signIn(username: sync.draftUsername, password: syncPassword, create: false); if sync.isSignedIn { syncPassword = "" } }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                .disabled(sync.draftUsername.isEmpty || syncPassword.isEmpty || sync.isSigningIn)
                if case .error(let m) = sync.status { Text(m).font(.app(.caption)).foregroundStyle(.red) }
                Text("Use the same username and password as on cadenceplanner.vercel.app (or create an account here). You stay signed in on this Mac until you sign out.")
                    .font(.app(.caption)).foregroundStyle(.secondary)
            }
        } header: {
            Text("Sync with Cadence Web")
        } footer: {
            Text("Tasks, completions, reflections and shared settings sync both ways about every minute and a few seconds after each change. Google sign-in and calendar picks stay on each device.")
                .font(.app(.caption)).foregroundStyle(.secondary)
        }
    }

    private var notificationsSection: some View {
        Section {
            HStack {
                Label(statusText, systemImage: authStatus == .authorized ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(authStatus == .authorized ? .green : .orange)
                Spacer()
                if authStatus == .notDetermined {
                    Button("Allow notifications") {
                        Task { await Notifier.shared.requestAuthorization(); authStatus = await Notifier.shared.authorizationStatus() }
                    }
                }
                Button("Open Notification Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
            }
            Text("To make macOS notifications stay on screen until you act on them, set Cadence's style to “Persistent” in System Settings › Notifications. Cadence's own on-screen banners always stay until dismissed.")
                .font(.app(.caption)).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Default alert style for new tasks").font(.app(.callout).weight(.medium))
                ChannelToggles(channels: $store.settings.defaultChannels, showDetail: true)
            }
            Picker("Tasks without a time remind at", selection: $store.settings.untimedReminderMinutes) {
                ForEach(Array(stride(from: 5 * 60, through: 22 * 60, by: 30)), id: \.self) { m in
                    Text(timeString(minutes: m)).tag(m)
                }
            }
            Picker("On-screen banners", selection: $store.settings.bannerAutoDismissSeconds) {
                Text("Stay until dismissed").tag(0)
                Text("Hide after 10 seconds").tag(10)
                Text("Hide after 30 seconds").tag(30)
                Text("Hide after 2 minutes").tag(120)
            }
            HStack {
                Button("Send a test reminder") {
                    Notifier.shared.deliver(AlertContent(kind: .test, title: "Test reminder",
                                                         body: "This is how Cadence reminders will look.",
                                                         symbol: "bell.badge.fill", tint: .blue),
                                            channels: store.settings.defaultChannels)
                }
                Button("Show check-in window") { engine.triggerCheckIn(reason: .manual) }
            }
        } header: {
            Text("Notifications")
        }
    }

    @AppStorage("sidebarHidden") private var sidebarHidden = ""
    private var sidebarSection: some View {
        Section {
            ForEach(SidebarGroup.all) { g in
                Toggle(isOn: Binding(get: { !sidebarHidden.split(separator: ",").map(String.init).contains(g.name) }, set: { show in
                    var h = Set(sidebarHidden.split(separator: ",").map(String.init))
                    if show { h.remove(g.name) } else { h.insert(g.name) }
                    sidebarHidden = h.sorted().joined(separator: ",")
                })) {
                    Text(g.name)
                    Text(g.screens.map(\.title).joined(separator: ", ")).font(.app(.caption)).foregroundStyle(.secondary)
                }
            }
            Text("Hidden sections are only hidden on this Mac. Click a section's heading in the sidebar to fold it.")
                .font(.app(.caption)).foregroundStyle(.secondary)
        } header: {
            Text("Sidebar")
        }
    }

    private var ringSection: some View {
        Section {
            RingModePicker().pickerStyle(.radioGroup)
            Picker("Until-done tasks and project subtasks count today when", selection: $store.settings.projectTodayDays) {
                ForEach(projectTodayChoices, id: \.0) { Text($0.1).tag($0.0) }
            }
            Text("Click the ring on Today to switch quickly. Urgent items always count today. Syncs to your iPhone and the web.")
                .font(.app(.caption)).foregroundStyle(.secondary)
        } header: {
            Text("Today's progress ring")
        }
    }

    private var nudgeSection: some View {
        Section {
            Toggle("Remind me to check my checklist while I'm using the Mac", isOn: $store.settings.nudgeEnabled)
            if store.settings.nudgeEnabled {
                Picker("Every", selection: $store.settings.nudgeIntervalMinutes) {
                    ForEach([15, 20, 30, 45, 60, 90, 120], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Toggle("Skip when everything is already done", isOn: $store.settings.nudgeOnlyWhenIncomplete)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Alert style").font(.app(.callout).weight(.medium))
                    ChannelToggles(channels: $store.settings.nudgeChannels)
                }
                Text("Paused while the screen is locked or asleep. Next reminder around \(timeString(engine.nextNudge)).")
                    .font(.app(.caption)).foregroundStyle(.secondary)
            }
        } header: {
            Text("Recurring checklist reminder")
        }
    }

    private var checkInSection: some View {
        Section {
            Toggle("When Cadence starts (including at login)", isOn: $store.settings.checkInOnLaunch)
            Toggle("When the Mac wakes from sleep", isOn: $store.settings.checkInOnWake)
            Toggle("When the screen is unlocked", isOn: $store.settings.checkInOnUnlock)
            Toggle("Only if something is still unchecked", isOn: $store.settings.checkInOnlyWhenIncomplete)
            VStack(alignment: .leading, spacing: 6) {
                Text("Alert style").font(.app(.callout).weight(.medium))
                ChannelToggles(channels: $store.settings.checkInChannels)
            }
        } header: {
            Text("Check-in when you open your computer")
        }
    }

    private var reflectionSection: some View {
        Section {
            Stepper(value: $store.settings.minReflectionWords, in: 20...300, step: 5) {
                Text("Minimum reflection length: \(store.settings.minReflectionWords) words")
            }
            Text("Every checklist item needs a reflection before it can be checked off. The minimum can't go below 20 words.")
                .font(.app(.caption)).foregroundStyle(.secondary)
        } header: {
            Text("Reflections")
        }
    }

    private var startupSection: some View {
        Section {
            Toggle("Open Cadence automatically when I log in (on by default)", isOn: Binding(get: { loginItemOn }, set: setLoginItem))
            if SMAppService.mainApp.status == .requiresApproval {
                Text("macOS needs your approval in System Settings › General › Login Items.")
                    .font(.app(.caption)).foregroundStyle(.orange)
            }
            if let loginError { Text(loginError).font(.app(.caption)).foregroundStyle(.red) }
            Toggle("Run in the background", isOn: Binding(get: { runInBackground }, set: { runInBackground = $0; WindowManager.runsInBackground = $0 }))
            Text(runInBackground
                 ? "When you close the window, Cadence leaves the Dock and keeps running in the menu bar, so reminders, nudges and check-ins keep coming. When it starts at login it opens quietly. Open it any time from the menu bar icon."
                 : "Cadence stays in the Dock when you close the window. It keeps running either way; quit it from the menu bar icon.")
                .font(.app(.caption)).foregroundStyle(.secondary)
            Text("Recommended: turn on both, since reminders only fire while Cadence is running.")
                .font(.app(.caption)).foregroundStyle(.secondary)
        } header: {
            Text("Startup")
        }
    }

    private var googleSection: some View {
        Section {
            if google.isConnected {
                HStack {
                    Label("Connected" + (google.account.map { " as \($0)" } ?? ""), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Refresh") { Task { await google.loadCalendars(); google.reloadEvents() } }
                    Button("Disconnect", role: .destructive) { google.disconnect() }
                }
                if google.viaServer {
                    Text("Using the Google connection from your Cadence account, so it's the same on the web and every device. Disconnecting here disconnects it everywhere.")
                        .font(.app(.caption)).foregroundStyle(.secondary)
                }
                Toggle("Show Google events in Cadence calendars", isOn: $store.settings.showGoogleEvents)
                if google.viaServer {
                    if google.tasksGranted {
                        Toggle("Sync Google Tasks (they show up as tasks kept until done; checking one off completes it in Google)", isOn: $store.settings.syncGoogleTasks)
                    } else {
                        HStack {
                            Text("Google Tasks: your Google connection is from before Cadence supported it. Connect again on the website to add it.")
                                .font(.app(.caption)).foregroundStyle(.secondary)
                            Spacer()
                            Link("Open website settings", destination: URL(string: "\(SyncService.defaultServer)/app/settings")!)
                        }
                    }
                }
                Picker("Remind me before Google events", selection: $store.settings.googleEventReminderMinutes) {
                    Text("Off").tag(0)
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                if !google.calendars.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Calendars to show and check for busy times").font(.app(.callout).weight(.medium))
                        ForEach(google.calendars) { cal in
                            Toggle(isOn: calendarBinding(cal)) {
                                HStack(spacing: 6) {
                                    Circle().fill(cal.colorHex.flatMap(Color.init(hex:)) ?? .blue).frame(width: 9, height: 9)
                                    Text(cal.summary)
                                    if cal.primary { Text("primary").font(.app(.caption)).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(sync.isSignedIn
                         ? "Connect Google Calendar once on the website. This Mac uses that connection automatically."
                         : "Sign in to sync (above), then connect Google Calendar on the website. This Mac uses that connection automatically.")
                    HStack {
                        Link(destination: URL(string: "https://cadenceplanner.vercel.app/app/settings")!) {
                            Label("Connect on the website", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!sync.isSignedIn)
                        Button("Check again") { Task { await google.checkServer() } }
                            .disabled(!sync.isSignedIn)
                    }
                }
                .font(.app(.callout))
                DisclosureGroup("Advanced: use this Mac's own Google client") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("One-time setup (about 5 minutes):").font(.app(.callout).weight(.medium))
                    Text("1. Open Google Cloud Console, create a project, and enable the **Google Calendar API**.")
                    Text("2. Under **OAuth consent screen**, choose External and add your Google account as a test user.")
                    Text("3. Under **Credentials**, create an **OAuth client ID** with application type **Desktop app**.")
                    Text("4. Paste the Client ID and Client secret below, then Connect.")
                    Link("Open Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                }
                .font(.app(.callout))
                TextField("Client ID", text: $store.settings.googleClientID, prompt: Text("…apps.googleusercontent.com")).multilineTextAlignment(.leading)
                HStack {
                    if showSecret {
                        TextField("Client secret", text: $store.settings.googleClientSecret).multilineTextAlignment(.leading)
                    } else {
                        SecureField("Client secret", text: $store.settings.googleClientSecret).multilineTextAlignment(.leading)
                    }
                    Button { showSecret.toggle() } label: { Image(systemName: showSecret ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                }
                HStack {
                    if google.isSigningIn {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in in your browser…").foregroundStyle(.secondary)
                        Button("Cancel") { google.cancelSignIn() }
                    } else {
                        Button("Connect Google Calendar") { Task { await google.connect() } }
                            .disabled(store.settings.googleClientID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                }
            }
            if let err = google.lastError {
                Text(err).font(.app(.caption)).foregroundStyle(.red)
            }
        } header: {
            Text("Google Calendar")
        }
    }

    private var calendlySection: some View {
        Section {
            if calendly.isConnected {
                HStack {
                    Label("Connected" + (calendly.userName.map { " as \($0)" } ?? ""), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    if calendly.isWorking { ProgressView().controlSize(.small) }
                    Button("Refresh") { Task { await calendly.loadProfile() } }
                    Button("Disconnect", role: .destructive) { calendly.disconnect() }
                }
                if let url = calendly.schedulingURL {
                    HStack {
                        Text(url.absoluteString).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        Spacer()
                        Button("Copy booking page link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                    }
                }
            } else {
                Text("In Calendly, open **Integrations › API & Webhooks**, generate a **Personal Access Token**, and paste it here. Your booked meetings will show up on your checklist (without notifications), and your booking links appear on the Booking page.")
                    .font(.app(.callout))
                Link("Open Calendly API settings", destination: URL(string: "https://calendly.com/integrations/api_webhooks")!)
                HStack {
                    SecureField("Personal Access Token", text: $calendlyToken).multilineTextAlignment(.leading)
                    Button("Connect") { Task { await calendly.connect(token: calendlyToken); if calendly.isConnected { calendlyToken = ""; await importer.importNow() } } }
                        .buttonStyle(.borderedProminent)
                        .disabled(calendlyToken.trimmingCharacters(in: .whitespaces).isEmpty || calendly.isWorking)
                }
            }
            if let e = calendly.lastError { Text(e).font(.app(.caption)).foregroundStyle(.red) }
        } header: {
            Text("Calendly")
        }
    }

    private var importSection: some View {
        Section {
            Toggle("Import Google Calendar events and Calendly meetings onto my checklist", isOn: $store.settings.autoImportCalendars)
            Stepper("Import the next \(store.settings.importDaysAhead) days", value: $store.settings.importDaysAhead, in: 1...60)
            HStack {
                Button {
                    Task { await importer.importNow() }
                } label: {
                    Label(importer.isImporting ? "Importing…" : "Import now", systemImage: "square.and.arrow.down")
                }
                .disabled(importer.isImporting || !(google.isConnected || calendly.isConnected))
                if importer.isImporting { ProgressView().controlSize(.small) }
                Spacer()
                if let s = importer.lastSummary { Text(s).font(.app(.caption)).foregroundStyle(.secondary).lineLimit(2) }
            }
            Text("Imported items never notify you (you can turn notifications on for any single one in its editor). Deleting one hides it for good. Google Calendar is re-checked every 2 minutes (and when Cadence comes to the front), so edits, moves and deletions there show up here quickly; Calendly every 30 minutes.")
                .font(.app(.caption)).foregroundStyle(.secondary)
        } header: {
            Text("Calendar imports")
        }
    }

    private var presetsSection: some View {
        Section {
            if store.settings.taskPresets.isEmpty {
                Text("No presets. Make one from the New Task window.").foregroundStyle(.secondary)
            }
            ForEach($store.settings.taskPresets) { $p in
                HStack(spacing: 10) {
                    Circle().fill(p.color.color).frame(width: 10, height: 10)
                    TextField("Name", text: $p.name).labelsHidden().frame(maxWidth: 200).multilineTextAlignment(.leading)
                    Text(p.summary).font(.app(.caption)).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button(role: .destructive) { store.settings.taskPresets.removeAll { $0.id == p.id } } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete preset")
                }
            }
        } header: {
            Text("Task presets")
        } footer: {
            Text("Saved combinations of conditions (repeat, keep until done, due date, reminders, color…). Pick one at the top of the New Task window, or save the current one there with “Save as preset”.")
                .font(.app(.caption)).foregroundStyle(.secondary)
        }
    }

    private var availabilitySection: some View {
        Section {
            WeekdayPicker(selection: $store.settings.availability.weekdays)
            Picker("From", selection: $store.settings.availability.startMinutes) {
                ForEach(Array(stride(from: 6 * 60, through: 20 * 60, by: 30)), id: \.self) { Text(timeString(minutes: $0)).tag($0) }
            }
            Picker("Until", selection: $store.settings.availability.endMinutes) {
                ForEach(Array(stride(from: 8 * 60, through: 23 * 60, by: 30)), id: \.self) { Text(timeString(minutes: $0)).tag($0) }
            }
            Picker("Breathing room around closed items", selection: $store.settings.availability.bufferMinutes) {
                ForEach([0, 5, 10, 15, 30], id: \.self) { Text($0 == 0 ? "None" : "\($0) minutes").tag($0) }
            }
        } header: {
            Text("Open hours")
        } footer: {
            Text("When you're normally free to be booked. Booking shows what's left of these hours after your closed tasks and events.")
                .font(.app(.caption)).foregroundStyle(.secondary)
        }
    }

    private var dataSection: some View {
        Section {
            HStack {
                Text(store.fileURL.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL]) }
            }
            HStack(spacing: 16) {
                Link("Privacy Policy", destination: URL(string: "https://cadenceplanner.vercel.app/privacy")!)
                Link("Terms of Service", destination: URL(string: "https://cadenceplanner.vercel.app/terms")!)
            }
            .font(.app(.caption))
        } header: {
            Text("Data")
        }
    }

    // MARK: Helpers

    private var statusText: String {
        switch authStatus {
        case .authorized: return "Notifications are allowed"
        case .provisional: return "Notifications are delivered quietly"
        case .denied: return "Notifications are turned off for Cadence — on-screen banners are used instead"
        default: return "Notification permission not requested yet"
        }
    }

    private func setLoginItem(_ on: Bool) {
        do {
            try LoginItem.set(on)
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        loginItemOn = SMAppService.mainApp.status == .enabled
    }

    private func calendarBinding(_ cal: GCalendar) -> Binding<Bool> {
        Binding(get: {
            let ids = store.settings.googleCalendarIDs
            return ids.isEmpty ? cal.primary : ids.contains(cal.id)
        }, set: { on in
            var ids = store.settings.googleCalendarIDs
            if ids.isEmpty, let primary = google.calendars.first(where: \.primary) { ids = [primary.id] }
            if on { if !ids.contains(cal.id) { ids.append(cal.id) } } else { ids.removeAll { $0 == cal.id } }
            store.settings.googleCalendarIDs = ids
            google.reloadEvents()
        })
    }
}
