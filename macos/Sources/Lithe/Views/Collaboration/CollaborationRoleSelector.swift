import SwiftUI
import LitheCoreContracts

struct CollaborationRoleSelector: View {
    let role: PiAgentRole
    @ObservedObject var feature: CollaborationFeatureModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var diagnostics: AIProviderDiagnosticsFeatureModel
    private var provider: AIProviderProfile? { feature.modelSettings.provider(for: role, in: settings.commitMessageAI) }
    private var isPresentation: Bool { role == .presentation }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(isPresentation ? "演示" : "开发").font(LitheTheme.uiFont(size: 11, weight: .semibold))
                    .foregroundStyle(isPresentation ? LitheTheme.secondaryText : LitheTheme.accent)
                LitheMenu {
                    for candidate in settings.commitMessageAI.providers {
                        LitheContextMenuItem.action(candidate.name, localizesTitle: false, checked: candidate.id == provider?.id) {
                            if isPresentation { feature.modelSettings.presentationProviderID = candidate.id; feature.modelSettings.presentationModel = "" }
                            else { feature.modelSettings.developmentProviderID = candidate.id; feature.modelSettings.developmentModel = "" }
                        }
                    }
                } label: {
                    HStack {
                        Text(provider?.name ?? "选择服务商").lineLimit(1)
                        Spacer(minLength: 0)
                        LitheIDEAIcon(resourcePath: "expui/general/chevronDown.svg", size: 16)
                    }
                }.buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 8, height: 28, fontSize: 11))
            }
            HStack(spacing: 6) {
                TextField(provider?.model ?? "模型名称", text: Binding(
                    get: { isPresentation ? feature.modelSettings.presentationModel : feature.modelSettings.developmentModel },
                    set: { if isPresentation { feature.modelSettings.presentationModel = $0 } else { feature.modelSettings.developmentModel = $0 } }))
                    .litheSettingsTextField()
                LitheMenu {
                    for name in diagnostics.models {
                        LitheContextMenuItem.action(name, localizesTitle: false, checked: name == provider?.model) {
                            if isPresentation { feature.modelSettings.presentationModel = name } else { feature.modelSettings.developmentModel = name }
                        }
                    }
                    LitheContextMenuItem.separator
                    LitheContextMenuItem.action("拉取模型") { diagnostics.fetchModels() }
                } label: { Text("模型") }
                    .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 8, height: 28, fontSize: 11))
                    .disabled(provider == nil || diagnostics.busy)
                Button(diagnostics.busy ? "取消" : "测试") {
                    if diagnostics.busy { diagnostics.cancel() } else { diagnostics.testConnection() }
                }.buttonStyle(.plain).disabled(provider == nil)
            }
            if diagnostics.connectionState == .ready {
                Text("短消息测试通过").foregroundStyle(LitheTheme.success)
            }
            if let error = diagnostics.connectionError ?? diagnostics.modelError { Text(error).foregroundStyle(LitheTheme.warning) }
        }
        .font(LitheTheme.uiFont(size: 10))
        .onAppear { diagnostics.bind(provider) }
        .onChange(of: provider) { diagnostics.bind($0) }
        .onDisappear { diagnostics.cancel() }
    }
}

struct CollaborationQuestionComposer: View {
    @ObservedObject var playback: CollaborationPlaybackModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !playback.answer.isEmpty {
                DisclosureGroup("关于当前记录的回答") {
                    ScrollView { Text(playback.answer).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 140).litheScrollViewChrome()
                }.font(LitheTheme.uiFont(size: 11))
            }
            HStack(spacing: 8) {
                TextField("问问这次修改为什么这样做…", text: $playback.question)
                    .litheSettingsTextField().onSubmit { playback.ask() }
                Button(playback.questionBusy ? "回答中" : "提问") { playback.ask() }
                    .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 9, height: 28, fontSize: 11))
                    .disabled(playback.questionBusy || playback.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
