import SwiftUI

struct CollaborationBudgetsView: View {
    @ObservedObject var feature: CollaborationFeatureModel
    var body: some View {
        DisclosureGroup("调用预算与用量") {
            VStack(alignment: .leading, spacing: 8) {
                budget("并行开发任务", value: $feature.modelSettings.maximumParallelTasks, values: [1, 2, 3, 4, 6, 8], suffix: "个")
                budget("单任务时间", value: $feature.modelSettings.developmentTimeoutSeconds, values: [60, 180, 600, 1800, 3600], suffix: "秒")
                budget("开发单次输出", value: $feature.modelSettings.developmentOutputTokens, values: [2048, 4096, 8192, 16384, 32768], suffix: "tokens")
                budget("开发累计用量", value: $feature.modelSettings.developmentTokenBudget, values: [16_000, 64_000, 200_000, 500_000], suffix: "tokens / 任务")
                budget("演示单次输出", value: $feature.modelSettings.presentationOutputTokens, values: [512, 1024, 2048, 4096, 8192], suffix: "tokens")
                budget("演示累计用量", value: $feature.modelSettings.presentationTokenBudget, values: [8000, 16_000, 32_000, 64_000], suffix: "tokens / 请求")
                budget("自动讲解次数", value: $feature.modelSettings.automaticNarrationRequests, values: [0, 4, 8, 16, 32], suffix: "次 / 会话")
                Text("累计用量在模型回报后检查；未回报时仅按时间和输出限制停止。实际费用以供应商账单为准。")
                    .foregroundStyle(LitheTheme.secondaryText)
                CollaborationUsageView(presentation: feature.presentation, playback: feature.playback)
            }.padding(.top, 6)
        }.font(LitheTheme.uiFont(size: 10))
    }
    private func budget(_ title: String, value: Binding<Int>, values: [Int], suffix: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            LitheMenu {
                for option in values {
                    LitheContextMenuItem.action("\(option) \(suffix)", localizesTitle: false, checked: value.wrappedValue == option) {
                        value.wrappedValue = option
                    }
                }
            } label: { Text("\(value.wrappedValue) \(suffix)") }
                .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 6, height: 24, fontSize: 10))
        }
    }
}

private struct CollaborationUsageView: View {
    @ObservedObject var presentation: CollaborationPresentationModel
    @ObservedObject var playback: CollaborationPlaybackModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(presentation.tasks) { task in CollaborationTaskUsage(task: task) }
            Text("演示回报：" + (playback.reportedTokens.map { "\(Int($0)) tokens" } ?? "暂无用量"))
        }.foregroundStyle(LitheTheme.secondaryText)
    }
}
private struct CollaborationTaskUsage: View {
    @ObservedObject var task: CollaborationTaskPreview
    var body: some View {
        Text((task.paths.first ?? "开发任务") + "：" + (task.reportedTokens.map { "\(Int($0)) tokens" } ?? "暂无用量"))
            .lineLimit(1).truncationMode(.middle)
    }
}
