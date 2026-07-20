import AppKit
import CCTransCore
import SwiftUI

// MARK: - Shared step header

private struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2).bold()
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Step 2: Permissions

struct PermissionsStepView: View {
    @ObservedObject var model: OnboardingFlowModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                StepHeader(
                    title: "Grant permissions",
                    subtitle: "CCTrans watches for the ⌘C hotkey and captures screenshots. macOS gates both behind a permission."
                )

                ForEach(model.permissions) { permission in
                    PermissionCardView(permission: permission)
                }

                // Shown whenever a grant is missing (the old Permission Helper always
                // showed it): macOS sometimes never auto-adds the app to a Privacy
                // list, and the drag card is the only recovery path in that state.
                if !model.allGranted {
                    AppBundleDragCard(
                        appBundleURL: model.appBundleURL,
                        onReveal: model.revealAppBundle
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PermissionCardView: View {
    let permission: OnboardingFlowModel.Permission

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: permission.symbol)
                .font(.title3)
                .foregroundStyle(permission.granted ? Color.green : Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(permission.title).bold()
                Text(permission.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                StatusPill(granted: permission.granted)
                if !permission.granted {
                    // App Review 5.1.1(iv): the priming button shown before the OS
                    // prompt must not say "Grant"/"Allow"; Apple asks for neutral
                    // wording like "Continue".
                    Button("Continue") { permission.request() }
                        .controlSize(.small)
                    // Always reachable (not gated on a prior attempt): macOS shows
                    // each OS permission dialog only once, so after any earlier
                    // denial Settings is the only remaining grant path.
                    if let fallback = permission.fallback {
                        Button("Open Settings") { fallback() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(permission.granted ? Color.green.opacity(0.4) : Color(NSColor.separatorColor), lineWidth: 1)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: permission.granted)
    }
}

private struct StatusPill: View {
    let granted: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
            Text(granted ? "Ready" : "Not granted")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(granted ? Color.green : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(granted ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
        )
    }
}

// MARK: - Step 1: Choose Model

private struct ModelOption: Identifiable {
    let provider: TranslationProvider
    let symbol: String
    let subtitle: String
    let badges: [String]
    let recommended: Bool
    var id: TranslationProvider { provider }
}

struct ModelStepView: View {
    @ObservedObject var model: OnboardingFlowModel

    // Local Model (Python-backed Hy-MT2) cannot run under the App Sandbox, so the
    // MAS build drops that row entirely (compile-gated so it never links).
    private var options: [ModelOption] {
        var rows: [ModelOption] = [
            ModelOption(provider: .appleTranslation, symbol: "apple.logo",
                        subtitle: "macOS built-in, offline", badges: ["Free", "On-device"], recommended: false),
        ]
        #if !MAS_BUILD
        rows.append(ModelOption(provider: .localHyMT2, symbol: "desktopcomputer",
                                subtitle: "Hy-MT2 on your Mac", badges: ["Free", "Offline"], recommended: true))
        #endif
        rows.append(ModelOption(provider: .kargnasManaged, symbol: "cloud.fill",
                                subtitle: "Managed cloud, just works", badges: ["No API key"], recommended: false))
        rows.append(ModelOption(provider: .openRouter, symbol: "key.fill",
                                subtitle: "Any LLM, best quality", badges: ["Your API key"], recommended: false))
        return rows
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    StepHeader(
                        title: "Choose a model",
                        subtitle: "Pick how CCTrans translates. You can fine-tune the model in Settings later."
                    )

                    // Vertical rows instead of a 2×2 card grid: the grid's
                    // minHeight-108 cards pushed the cloud follow-up panel past the
                    // fixed 520pt window, which hid the anonymous button and
                    // soft-locked Next. Rows keep the model area ~150pt.
                    VStack(spacing: 6) {
                        ForEach(options) { option in
                            ModelRowView(
                                option: option,
                                isSelected: model.selectedProvider == option.provider,
                                action: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        model.selectProvider(option.provider)
                                    }
                                }
                            )
                        }
                    }

                    inlineFollowUp
                        .id("model-inline-follow-up")
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.selectedProvider)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                guard model.selectedProvider == .kargnasManaged else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo("model-inline-follow-up", anchor: .bottom)
                }
            }
            .onChange(of: model.selectedProvider) { _, provider in
                guard provider == .kargnasManaged else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                    proxy.scrollTo("model-inline-follow-up", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private var inlineFollowUp: some View {
        switch model.selectedProvider {
        case .openRouter:
            OpenRouterKeyField(model: model)
                .transition(.opacity.combined(with: .move(edge: .top)))
        case .appleTranslation:
            if let download = model.translationDownload {
                TranslationDownloadSection(model: download)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        case .localHyMT2:
            InlineNote(text: "Downloads automatically on first use.")
                .transition(.opacity.combined(with: .move(edge: .top)))
        case .kargnasManaged:
            CloudAccountFollowUp(model: model)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

private struct ModelRowView: View {
    let option: ModelOption
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // Radio indicator: ring unselected, accent "dot" (thick border,
                // clear center) when selected — mirrors NSButton radio style.
                Circle()
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.6),
                                  lineWidth: isSelected ? 5 : 1.5)
                    .frame(width: 16, height: 16)
                    .animation(.spring(response: 0.25, dampingFraction: 0.9), value: isSelected)

                Image(systemName: option.symbol)
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    .frame(width: 22)

                Text(option.provider.title)
                    .font(.callout.weight(.semibold))
                Text(option.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    ForEach(option.badges, id: \.self) { badge in
                        BadgeView(text: badge, tint: .secondary)
                    }
                    if option.recommended {
                        BadgeView(text: "Recommended", tint: .accentColor)
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color(NSColor.separatorColor),
                            lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct BadgeView: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

private struct InlineNote: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct OpenRouterKeyField: View {
    @ObservedObject var model: OnboardingFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OpenRouter API key")
                .font(.caption.weight(.semibold))
            HStack(spacing: 8) {
                SecureField("sk-or-…", text: $model.openRouterKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.saveOpenRouterKey() }
                Button("Save") { model.saveOpenRouterKey() }
                    .disabled(model.openRouterKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = model.openRouterKeyError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if model.openRouterKeySaved {
                Label("Saved.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if model.openRouterKeyWarning {
                Label("No key yet — OpenRouter won't translate until you add one.", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Stored locally in your CCTrans credentials file. You can add it later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CloudAccountFollowUp: View {
    @ObservedObject var model: OnboardingFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let account = model.accountState.account {
                signedInContent(account)
            } else {
                choiceContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }

    private var choiceContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Use CCTrans Cloud")
                .font(.caption.weight(.semibold))
            Text("Sign in securely in your browser with Apple, Google, or email.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: model.signInWithBrowser) {
                Label("Continue in Browser", systemImage: "safari.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.accountState.isLoading)
            .accessibilityLabel("Continue in Browser")

            // MAS-only: anonymous cloud translation needs a server-verifiable device
            // (AppTransaction / App Store receipt on MAS, dev token in QA). Direct
            // builds have neither — translate() throws .attestUnavailable — so the
            // button would be dead UI there.
            #if MAS_BUILD
            Button("Start Free Without an Account", action: model.continueWithoutAccount)
                .buttonStyle(.link)
                .disabled(model.accountState.isLoading)
            #endif

            accountStatus
        }
    }

    private func signedInContent(_ account: CctransAccountSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Account ready", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)
            Text(account.email)
                .font(.callout)
                .textSelection(.enabled)
            if account.emailVerified {
                Text("Your account is verified. Continue to finish model setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label(
                    "Verification pending. You can continue now, but purchases stay unavailable until the email is verified.",
                    systemImage: "envelope.badge"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var accountStatus: some View {
        Group {
            if model.accountState.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Signing in…")
                        .foregroundStyle(.secondary)
                }
            } else if model.accountState.isAnonymous {
                Label("Free without an account selected.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if let failure = model.accountState.failure {
                Label(failureMessage(failure), systemImage: failureSymbol(failure))
                    .foregroundStyle(failure == .cancelled ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                #if MAS_BUILD
                Text("Choose an account option to continue with CCTrans Cloud.")
                    .foregroundStyle(.secondary)
                #else
                Text("Sign in to continue with CCTrans Cloud.")
                    .foregroundStyle(.secondary)
                #endif
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func failureMessage(_ failure: CctransOnboardingAccountState.Failure) -> String {
        switch failure {
        case let .request(message):
            message
        case .cancelled:
            "Browser sign-in was cancelled."
        }
    }

    private func failureSymbol(_ failure: CctransOnboardingAccountState.Failure) -> String {
        switch failure {
        case .cancelled:
            "xmark.circle"
        case .request:
            "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Step 3: Try It

struct TryItStepView: View {
    @ObservedObject var model: OnboardingFlowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                title: "Try it out",
                subtitle: "Select the sentence below, hold ⌘ and tap C twice."
            )

            // A real, selectable sample so the very first translation can happen
            // without leaving the window.
            Text(model.trySampleText)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )

            HStack(spacing: 6) {
                KeyCapView(label: "⌘", compact: true)
                Text("+").foregroundStyle(.secondary)
                KeyCapView(label: "C", compact: true)
                KeyCapView(label: "C", compact: true)
            }

            statusRow

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var statusRow: some View {
        if model.hasTranslated {
            ZStack(alignment: .leading) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                    Text("Translated! You're all set.")
                        .font(.callout.weight(.medium))
                }
                // One-shot celebration; skipped under reduced motion (fade only).
                if !reduceMotion {
                    ConfettiView()
                        .frame(height: 40)
                        .allowsHitTesting(false)
                }
            }
            .transition(.opacity)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for your first translation…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Ported drag affordance
//
// Kept verbatim from the old onboarding window: when macOS does not auto-add
// CCTrans to a Privacy list, the user can drag the real app bundle into it.

private struct AppBundleDragCard: View {
    let appBundleURL: URL
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            DraggableAppIcon(appBundleURL: appBundleURL)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(appBundleURL.lastPathComponent).bold()
                Text("Drag the app icon into the open Privacy list if macOS does not add it automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(appBundleURL.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Reveal") { onReveal() }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }
}

// Internal (not private): also the drag source inside PrivacyDragOverlay's
// floating chip, so both surfaces share one drag implementation.
struct DraggableAppIcon: NSViewRepresentable {
    let appBundleURL: URL

    func makeNSView(context: Context) -> AppIconDragView {
        AppIconDragView(appBundleURL: appBundleURL)
    }

    func updateNSView(_ nsView: AppIconDragView, context: Context) {
        nsView.appBundleURL = appBundleURL
    }
}

final class AppIconDragView: NSImageView, NSDraggingSource {
    var appBundleURL: URL {
        didSet {
            image = NSWorkspace.shared.icon(forFile: appBundleURL.path)
        }
    }

    init(appBundleURL: URL) {
        self.appBundleURL = appBundleURL
        super.init(frame: .zero)
        image = NSWorkspace.shared.icon(forFile: appBundleURL.path)
        imageScaling = .scaleProportionallyUpOrDown
        isEditable = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Hovering shows the open hand so the icon reads as grabbable; the system
    // swaps to closedHand on its own once a drag session begins.
    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDragged(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(appBundleURL.absoluteString, forType: .fileURL)
        item.setPropertyList([appBundleURL.path], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))

        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }
}
