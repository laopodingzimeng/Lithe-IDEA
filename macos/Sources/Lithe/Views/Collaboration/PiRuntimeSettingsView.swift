import SwiftUI

struct PiRuntimeSettingsView: View {
    @ObservedObject var runtime: PiRuntimeFeatureModel
    let importPackage: () -> Void
    var body: some View {
        DisclosureGroup("协作运行包") {
            VStack(alignment: .leading, spacing: 8) {
                Text("兼容的运行包可独立更新。下载后解压，导入包含 lithe-pi-runtime.json 的目录；请使用你信任的来源。")
                    .foregroundStyle(LitheTheme.secondaryText)
                HStack {
                    Button(runtime.busy ? "处理中" : "导入运行包", action: importPackage)
                        .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 8, height: 26, fontSize: 11)).disabled(runtime.busy)
                    Button("刷新") { runtime.refresh() }.buttonStyle(.plain).disabled(runtime.busy)
                }
                if let snapshot = runtime.snapshot {
                    if snapshot.versions.isEmpty { Text("尚无可用运行包").foregroundStyle(LitheTheme.warning) }
                    ForEach(snapshot.versions) { version in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(version.version + (version.bundled ? " · 内置" : " · 本机导入"))
                                Text(version.available ? "Pi \(version.sdkVersion) · Node \(version.nodeVersion)" : "校验失败，请重新导入或切换后移除")
                                    .foregroundStyle(LitheTheme.secondaryText)
                            }
                            Spacer()
                            if snapshot.selectedID == version.id { Text("当前").foregroundStyle(LitheTheme.accent) }
                            else {
                                Button(snapshot.pendingID == version.id ? "等待空闲" : "使用") { runtime.select(version.id) }
                                    .buttonStyle(.plain).disabled(runtime.busy || !version.available)
                                if !version.bundled {
                                    Button("移除") { runtime.remove(version.id) }.buttonStyle(.plain)
                                        .disabled(runtime.busy || snapshot.pendingID == version.id || snapshot.activeRuns > 0)
                                }
                            }
                        }
                    }
                    if snapshot.pendingID != nil { Text("正在运行的任务继续使用原版本，全部结束后切换。") }
                    if let message = snapshot.message { Text(message).foregroundStyle(LitheTheme.warning) }
                }
                if let error = runtime.error { Text(error).foregroundStyle(LitheTheme.warning) }
            }.padding(.top, 6)
        }.font(LitheTheme.uiFont(size: 10))
        .onAppear { runtime.refresh() }
    }
}
