//
//  StoreKitManager.swift
//  StoreKitTest
//
//  Created by Subo on 11/28/25.
//

import Foundation
import StoreKit
import Combine

// 定义一个简单的错误枚举
enum StoreError: Error {
    case failedVerification
}

// 统一的购买/恢复结果，便于 UI 显示 Toast
enum FlowResult {
    case success(String)
    case failure(String)
    case cancelled(String)
    case pending(String)

    var message: String {
        switch self {
        case .success(let msg), .failure(let msg), .cancelled(let msg), .pending(let msg):
            return msg
        }
    }
}

// 定义商品 ID，必须和 .storekit 文件里的一致
enum ProductID: String, CaseIterable {
    case lifetime = "com.myapp.lifetime"    // 非消耗型
    /*
     注意下面两个订阅方式：月付和年付，它们属于同一个订阅组，必须将 Subscription Level 设置为不同的值
     Subscription Level（订阅等级）的数字越小，优先级越高。
     如果用户 从 Level 2（月付）转去 Level 1（年付），这在 Apple 的定义中属于 升级（Upgrade）。
     
     这种情况下订阅会发生什么变化呢？
     当用户在 同一个订阅组 内，从低等级（Level 2）切换到高等级（Level 1）时，会发生以下行为：
     1.立即生效：用户的“按月订阅”会立即停止，用户的“按年订阅”会立即开始。
     2.按比例退款：Apple 会自动计算“按月订阅”中剩余未使用的天数，并将这部分的钱退还给用户（通常是原路退回）。
     3.全额扣款：用户会被立即扣除“按年订阅”的全额费用。
     4.周期重置：订阅的续期日期（Renewal Date）会更新。比如今天是 11月29日，用户操作了升级，那么新的到期日就是明年的 11月29日。
     总结：用户现在的状态是“按年订阅”生效中，“按月订阅”已失效。用户获得了无缝的权益升级体验。
     
     开发过程总要如何处理这种情况：
     - 当用户在 App 内或系统设置里完成购买后，你的 Transaction.updates 监听器会收到一个新的 Transaction。
     - 你需要调用 Transaction.currentEntitlements。由于这两个商品在同一个订阅组，currentEntitlements 只会返回最新的那个（即 Level 1 的年付订阅）。
     - 代码逻辑：获取最新 Transaction -> 验证 -> 解锁 Level 1 对应的功能 -> 更新 UI 显示“年费会员”。
     */
    case monthly  = "com.myapp.pro.monthly" // 按月订阅，Level 2
    case yearly   = "com.myapp.pro.yearly"  // 按年订阅, Level 1
    
    case coins    = "com.myapp.coin.100"    // 消耗型
}

// 使用 MainActor 确保 UI 更新在主线程
@MainActor
class StoreKitManager: ObservableObject {
    static let shared = StoreKitManager()
    
    // 用于驱动 UI 显示的商品列表
    @Published var products: [Product] = []
    @Published var purchasedProductIDs = Set<String>() // 已买过的 ID (非消耗/订阅)
    @Published var coinBalance: Int = 0 // 消耗品余额模拟
    @Published var subscriptionStatus: String = "无订阅" // 订阅详细状态
    @Published var introOfferEligibility: [String: Bool] = [:] // 订阅体验/首购优惠资格缓存
    
    private var updatesTask: Task<Void, Never>? = nil
    
    private init() {
        // 1. App 启动时立即开始监听交易变化
        updatesTask = listenForTransactions()
    }
    
    deinit {
        updatesTask?.cancel()
    }
    
    /// 订阅用户或者终身版都视为 Pro 用户
    var isPro: Bool {
        return purchasedProductIDs.contains(ProductID.monthly.rawValue) || purchasedProductIDs.contains(ProductID.yearly.rawValue) || purchasedProductIDs.contains(ProductID.lifetime.rawValue)
    }
    
    // MARK: - 1. 获取商品
    func requestProducts() async {
        log("开始请求商品列表: \(ProductID.allCases.map { $0.rawValue }.joined(separator: ", "))")
        do {
            let productIDs = Set(ProductID.allCases.map { $0.rawValue })
            
            // 这里会返回合法的 Product 对象数组
            let products = try await Product.products(for: productIDs)
            
            // 按需求排序（例如按价格）并更新 UI
            self.products = products.sorted(by: { $0.price < $1.price })
            
            for product in self.products {
                log("查找到商品: \(product.displayName) - \(product.displayPrice)")
                await updateIntroEligibility(for: product)
            }
            
            // 加载完商品后，立即检查用户当前的购买状态
            await updateCustomerProductStatus()
        } catch {
            log("获取商品失败: \(error)")
        }
    }
    
    // MARK: - 2. 发起购买
    
    /// 购买指定商品
    /// - Parameter product: 商品对象
    @discardableResult
    func purchase(_ product: Product) async -> FlowResult {
        log("准备购买商品: \(product.displayName) (\(product.id))，价格 \(product.displayPrice)")
        do {
            // 发起购买请求
            let result = try await product.purchase()
            
            // 处理购买结果
            switch result {
            case .success(let verification):
                // 购买成功，需验证交易
                log("购买成功返回，开始校验凭证...")
                let transaction = try checkVerified(verification)
                log("校验通过，交易 ID: \(transaction.id)")
                
                // 购买成功后，统一调用处理逻辑
                await handleTransaction(transaction)
                
                // 告诉苹果交易完成
                await transaction.finish()
                log("已完成交易并上报 finish")
                return .success("购买成功")
            case .userCancelled:
                log("用户取消了支付")
                return .cancelled("用户取消")
            case .pending:
                log("交易挂起 (如家长控制)")
                return .pending("交易挂起")
            @unknown default:
                log("未知状态")
                return .failure("未知状态")
            }
        } catch {
            log("购买失败: \(error)")
            return .failure("购买失败: \(error.localizedDescription)")
        }
    }
    
    private func handleTransaction(_ transaction: Transaction) async {
        if transaction.productType == .consumable {
            // 【情况 A】：消耗型商品 (金币)
            // 消耗型商品是“一次性”的，不会存在于 currentEntitlements 中
            // 所以我们必须在这里手动处理计数
            // 建议：真实项目中应记录 transaction.id 防止重复加币
            coinBalance += 100
            log("金币到账 +100")
        } else {
            // 【情况 B】：订阅 或 非消耗型 (永久版)
            // ⚠️ 关键点：不要只是 insert 进去，而是触发“全量刷新”
            // 当用户从月付升级到年付，Apple 的 currentEntitlements 会自动把月付去掉，只留年付
            // 所以我们重新拉取一次，就能得到正确的唯一状态。
            await updateCustomerProductStatus()
        }
    }
    
    // MARK: - 3. 监听交易更新 (核心)
    // 处理应用外购买、自动续费、退款等情况
    private func listenForTransactions() -> Task<Void, Never> {
        return Task.detached {
            for await result in Transaction.updates {
                do {
                    let transaction = try await self.checkVerified(result)
                    
                    // 监听到变化，交给统一处理方法
                    await self.handleTransaction(transaction)
                    
                    // 结束交易 (如果不 finish，下次启动还会收到)
                    await transaction.finish()

                    self.log("监听到交易更新并已处理: \(transaction.productID)")
                } catch {
                    self.log("监听到的交易验证失败: \(error)")
                }
            }
        }
    }
    
    // MARK: - 4. 恢复购买 / 检查当前权益
    // 只要调用这个，就能把用户拥有的非消耗品和订阅刷出来
    func updateCustomerProductStatus() async {
        var activePurchasedIds: Set<String> = []
        
        // 遍历 Apple 认为当前有效的权益
        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)
                
                // 如果该交易已经被升级（即用户买了更高级别的订阅），则忽略旧的订阅
                if transaction.isUpgraded {
                    log("忽略已升级的旧订阅: \(transaction.productID)")
                    continue
                }
                
                // 如果交易已撤销（例如被升级覆盖、被退款），则跳过
                if let revocationDate = transaction.revocationDate, revocationDate < Date() {
                    log("该权益已被撤销/升级覆盖: \(transaction.productID)")
                    continue
                }
                
                // 1. 放入临时集合
                activePurchasedIds.insert(transaction.productID)
                
                // 2. 更新详细状态文案 (如果有多个订阅组，这里只会拿到每个组生效的那个)
                if transaction.productType == .autoRenewable {
                    await checkSubscriptionDetails(transaction)
                }
            } catch {
                log("权益验证失败: \(error)")
            }
        }
        
        self.purchasedProductIDs = activePurchasedIds
        
        // 如果集合是空的，重置状态文案
        if self.purchasedProductIDs.isEmpty {
            self.subscriptionStatus = "无订阅"
        }
        
        log("权益已刷新，当前生效: \(activePurchasedIds.joined(separator: ", "))")
    }
    
    // 手动强制恢复
    @discardableResult
    func restorePurchases() async -> FlowResult {
        log("开始恢复购买")
        do {
            // 1. 强制同步 App Store 交易记录
            // 这可能会提示用户输入 Apple ID 密码
            try await AppStore.sync()

            // 2. 同步完成后，重新检查权益
            await updateCustomerProductStatus()

            // 3. UI 提示
            log("Restore completed successfully")
            return .success("恢复成功")
        } catch {
            log("Restore failed: \(error)")
            return .failure("恢复失败: \(error.localizedDescription)")
        }
    }
    
    // MARK: - 5. 内部逻辑：验证与发货
    
    // 验证交易真实性
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            // 验证失败（可能是盗版或证书不对），抛出错误，不给权益
            throw StoreError.failedVerification
        case .verified(let safe):
            // 验证成功，返回安全的交易对象
            return safe
        }
    }
    
    // 检查订阅详细信息 (如：是否会续期)
    private func checkSubscriptionDetails(_ transaction: Transaction) async {
        // 通过 productID 找到对应的 Product
        guard let product = products.first(where: { $0.id == transaction.productID }),
              let subscription = product.subscription else { return }
        
        do {
            let statuses = try await subscription.status
            guard let status = statuses.first else { return }
            
            let renewalInfo = try checkVerified(status.renewalInfo)
            
            var statusText = ""
            switch status.state {
            case .subscribed: statusText = "订阅中"
            case .expired: statusText = "已过期"
            case .inGracePeriod: statusText = "宽限期 (扣费失败但可用)"
            case .revoked: statusText = "已撤销"
            case .inBillingRetryPeriod: statusText = "扣费重试中"
            default: statusText = "未知状态"
            }
            
            let autoRenewText = renewalInfo.willAutoRenew ? "自动续订开启" : "自动续订已关"
            self.subscriptionStatus = "\(statusText) - \(autoRenewText)"
            
        } catch {
            log("无法获取订阅详情: \(error)")
        }
    }
    
    // 检查是否有优惠
    func checkIntroOffer(for product: Product) async {
        if let subscription = product.subscription,
           let introOffer = subscription.introductoryOffer {

            // 检查用户是否有资格享受这个优惠
            // StoreKit 2 会自动根据用户历史判断 isEligible
            let isEligible = await subscription.isEligibleForIntroOffer

            if isEligible {
                if introOffer.paymentMode == .freeTrial {
                    log("免费试用 \(introOffer.period.value) \(introOffer.period.unit)")
                } else {
                    log("首月仅需: \(introOffer.price)")
                }
            } else {
                log("原价: \(product.price)")
            }
        }
    }

    // 缓存体验/首购优惠资格，供 UI 使用
    private func updateIntroEligibility(for product: Product) async {
        guard let subscription = product.subscription,
              subscription.introductoryOffer != nil else { return }
        let eligible = await subscription.isEligibleForIntroOffer
        await MainActor.run {
            introOfferEligibility[product.id] = eligible
            log("Intro offer eligibility for \(product.id): \(eligible)")
        }
    }

    // MARK: - 6. 日志工具
    nonisolated private func log(_ message: String) {
        // 独立于 MainActor，便于在后台 Task.detached 中调用
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let time = formatter.string(from: Date())
        print("[StoreKit] [\(time)] \(message)")
    }
    
    // 辅助方法：打印产品详情
    func displayProductInfo(_ product: Product) {
        print("━━━━━━━━━━━━━━━━━━━━━━")
        print("商品 ID: \(product.id)")
        print("名称: \(product.displayName)")
        print("描述: \(product.description)")
        print("价格: \(product.displayPrice)")  // 已格式化的价格字符串
        print("价格数值: \(product.price)")     // Decimal 类型
        print("货币代码: \(product.priceFormatStyle.currencyCode)")
        print("类型: \(product.type)")
        print("支持家庭共享: \(product.isFamilyShareable ? "是" : "否")")

        // 订阅专属信息
        if let subscription = product.subscription {
            print("━━━ 订阅信息 ━━━")
            print("订阅组 ID: \(subscription.subscriptionGroupID)")
            print("订阅周期: \(periodText(subscription.subscriptionPeriod, count: 1))")

            // 介绍性优惠（新用户优惠）
            if let introOffer = subscription.introductoryOffer {
                let introDescription = periodText(introOffer.period, count: introOffer.periodCount)
                print("新用户优惠: \(introOffer.displayPrice) • \(introDescription) • \(introOffer.paymentMode)")
            } else {
                print("新用户优惠: 无")
            }

            // 推介优惠
            if subscription.promotionalOffers.isEmpty {
                print("推介优惠: 无")
            } else {
                print("推介优惠 \(subscription.promotionalOffers.count) 个：")
                for offer in subscription.promotionalOffers {
                    let description = periodText(offer.period, count: offer.periodCount)
                    print("  - \(offer.id): \(offer.displayPrice) • \(description) • \(offer.paymentMode)")
                }
            }
        } else {
            print("非订阅商品，无订阅附加信息")
        }

        print("━━━━━━━━━━━━━━━━━━━━━━")
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
        let base = period.value > 1 ? "\(period.value)\(unit)" : unit
        return count > 1 ? "\(count) x \(base)" : base
    }

}
