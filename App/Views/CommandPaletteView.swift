import SwiftUI
import StockMonitorCore

@MainActor
struct CommandPaletteView: View {
    let onRoute: (StockMonitorRoute) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.stockMonitorPalette) private var palette
    @State private var query = ""
    @FocusState private var queryFocused: Bool

    private var matchingTabs: [StockMonitorTab] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return StockMonitorTab.allCases }
        return StockMonitorTab.allCases.filter {
            $0.displayName.localizedCaseInsensitiveContains(text) ||
            $0.rawValue.localizedCaseInsensitiveContains(text)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("导航") {
                    ForEach(matchingTabs, id: \.self) { tab in
                        Button {
                            choose(.tab(tab))
                        } label: {
                            Label(tab.displayName, systemImage: icon(for: tab))
                                .frame(minHeight: StockMonitorTokens.Size.minimumHitTarget,
                                       alignment: .leading)
                        }
                        .accessibilityHint("切换到\(tab.displayName)标签")
                    }
                }

                Section("证券") {
                    Button {
                        guard let route = routeForStockQuery else { return }
                        choose(route)
                    } label: {
                        Label("打开证券代码", systemImage: "magnifyingglass")
                            .frame(minHeight: StockMonitorTokens.Size.minimumHitTarget,
                                   alignment: .leading)
                    }
                    .disabled(routeForStockQuery == nil)
                    .accessibilityHint("已在自选中时打开监测；未在自选中时转到自选并预填代码，需手动添加")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(palette.paper0)
            .navigationTitle("命令")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "标签或 6 位证券代码")
            .searchFocused($queryFocused)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onSubmit(of: .search) {
                if let route = routeForStockQuery { choose(route) }
                else if let tab = matchingTabs.first { choose(.tab(tab)) }
            }
        }
        .tint(palette.accent)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { queryFocused = true }
    }

    private var routeForStockQuery: StockMonitorRoute? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard StockMonitorRoute.isSafeStockCode(text) else { return nil }
        return .stock(code: text)
    }

    private func choose(_ route: StockMonitorRoute) {
        onRoute(route)
        dismiss()
    }

    private func icon(for tab: StockMonitorTab) -> String {
        switch tab {
        case .market: "chart.xyaxis.line"
        case .watchlist: "star"
        case .monitor: "waveform.path.ecg"
        case .feed: "text.bubble"
        case .lab: "chart.bar.xaxis"
        case .settings: "slider.horizontal.3"
        }
    }
}
