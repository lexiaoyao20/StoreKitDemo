//
//  ContentView.swift
//  StoreKitDemo
//
//  Created by Subo on 11/28/25.
//

import SwiftUI
import StoreKit

struct ContentView: View {
    @StateObject var storeKit = StoreKitManager.shared
    @State private var toast: ToastData?
    @State private var isProcessing = false
    
    var body: some View {
        Group {
            if #available(macOS 13.0, iOS 16.0, *) {
                NavigationStack { mainContent }
            } else {
                NavigationView { mainContent }
            }
        }
    }

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                assetsCard
                storeCard
                actionsCard
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("StoreKit 2 Demo")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(backgroundColor)
        .task { await storeKit.requestProducts() }
        .overlay(alignment: .top) {
            ToastView(toast: toast)
                .padding(.horizontal, 16)
                .padding(.top, 10)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("我的资产")
                .font(.title2.weight(.semibold))
            Text("管理内购和订阅，实时查看余额与状态。")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var assetsCard: some View {
        sectionCard(title: "账户概览") {
            HStack(spacing: 12) {
                Label("金币余额", systemImage: "creditcard")
                    .font(.headline)
                Spacer()
                Text("\(storeKit.coinBalance)")
                    .font(.title3.monospacedDigit())
                    .foregroundColor(.orange)
            }
            Divider()
            HStack(spacing: 12) {
                Label("订阅状态", systemImage: "calendar.badge.clock")
                    .font(.headline)
                Spacer()
                // Pro 用户显示皇冠👑
                if storeKit.isPro {
                    ZStack {
                        LinearGradient(
                            colors: [Color(hex: "FFD700"), Color(hex: "FFB347")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .frame(width: 26, height: 26)
                        .cornerRadius(6)
                        
                        Image(systemName: "crown.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                Text(storeKit.subscriptionStatus)
                    .font(.callout)
                    .foregroundColor(.blue)
            }
        }
    }

    private var storeCard: some View {
        sectionCard(title: "商店") {
            if storeKit.products.isEmpty {
                Text("正在加载商品...")
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(storeKit.products) { product in
                        productRow(for: product)
                        if product.id != storeKit.products.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var actionsCard: some View {
        sectionCard(title: "操作") {
            Button {
                runFlowWithToast(loadingText: "正在恢复购买...") {
                    await storeKit.restorePurchases()
                }
            } label: {
                Label("恢复购买 (Restore)", systemImage: "arrow.uturn.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isProcessing)
        }
    }

    private func productRow(for product: Product) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(product.displayName)
                    .font(.headline)
                Text(product.description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                promoInfo(for: product)
            }
            Spacer()
            buyButton(for: product)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(borderColor, lineWidth: 0.8)
        )
    }
    
    // 抽取按钮逻辑视图
    @ViewBuilder
    func buyButton(for product: Product) -> some View {
        if product.type == .consumable {
            // 消耗型：永远显示价格，可以重复买
            Button(product.displayPrice) {
                runFlowWithToast(loadingText: "正在购买 \(product.displayName)...") {
                    await storeKit.purchase(product)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isProcessing)
            
        } else {
            // 非消耗/订阅：如果买过，显示“已拥有”
            if storeKit.purchasedProductIDs.contains(product.id) {
                Label("已拥有", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.green.opacity(0.12))
                    )
            } else {
                Button(product.displayPrice) {
                    runFlowWithToast(loadingText: "正在购买 \(product.displayName)...") {
                        await storeKit.purchase(product)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isProcessing)
            }
        }
    }

    private var backgroundColor: Color {
        #if os(macOS)
        Color(nsColor: .underPageBackgroundColor)
        #else
        Color(.systemGroupedBackground)
        #endif
    }

    private var cardBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(.systemBackground)
        #endif
    }

    private var borderColor: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color(.separator)
        #endif
    }

    // MARK: - Toast & Flow Helpers
    private func runFlowWithToast(loadingText: String, action: @escaping () async -> FlowResult) {
        isProcessing = true
        showToast(message: loadingText, style: .loading, autoHide: false)
        Task {
            let result = await action()
            await MainActor.run {
                isProcessing = false
                switch result {
                case .success(let message):
                    showToast(message: message, style: .success)
                case .failure(let message):
                    showToast(message: message, style: .failure)
                case .cancelled(let message):
                    showToast(message: message, style: .info)
                case .pending(let message):
                    showToast(message: message, style: .info)
                }
            }
        }
    }

    private func showToast(message: String, style: ToastStyle, autoHide: Bool = true) {
        let data = ToastData(message: message, style: style)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            toast = data
        }
        guard autoHide else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
            if toast?.id == data.id {
                withAnimation(.easeOut(duration: 0.22)) {
                    toast = nil
                }
            }
        }
    }

    // 推介/体验优惠展示
    @ViewBuilder
    private func promoInfo(for product: Product) -> some View {
        if let promo = product.subscription?.promotionalOffers.first {
            HStack(spacing: 6) {
                Image(systemName: "tag.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                Text("推介优惠: \(promo.displayPrice) • \(periodText(promo.period, count: promo.periodCount))")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        } else if let intro = product.subscription?.introductoryOffer {
            let eligible = storeKit.introOfferEligibility[product.id] ?? true
            if eligible {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Text(introText(intro))
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("体验优惠已使用")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func periodText(_ period: Product.SubscriptionPeriod, count: Int) -> String {
        let unit: String
        switch period.unit {
        case .day: unit = "天"
        case .week: unit = "周"
        case .month: unit = "月"
        case .year: unit = "年"
        @unknown default: unit = "周期"
        }
        return count > 1 ? "\(count)\(unit)" : unit
    }

    private func introText(_ intro: Product.SubscriptionOffer) -> String {
        switch intro.paymentMode {
        case .freeTrial:
            return "免费试用 \(intro.period.value) \(periodText(intro.period, count: intro.periodCount))"
        case .payUpFront:
            return "首期 \(intro.displayPrice) • \(periodText(intro.period, count: intro.periodCount))"
        case .payAsYouGo:
            return "优惠价 \(intro.displayPrice)/\(periodText(intro.period, count: 1)) 共 \(intro.periodCount) 期"
        default:
            return "体验优惠"
        }
    }
}

// MARK: - Color Extension
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}


#Preview {
    ContentView()
}
