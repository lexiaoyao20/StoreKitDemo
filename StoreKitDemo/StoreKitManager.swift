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
    case monthly  = "com.myapp.pro.monthly" // 订阅
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
        return purchasedProductIDs.contains(ProductID.monthly.rawValue) || purchasedProductIDs.contains(ProductID.lifetime.rawValue)
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
                
                // 发放权益
                await updatePurchasedStatus(transaction)
                
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
    
    // MARK: - 3. 监听交易更新 (核心)
    // 处理应用外购买、自动续费、退款等情况
    private func listenForTransactions() -> Task<Void, Never> {
        return Task.detached {
            for await result in Transaction.updates {
                do {
                    let transaction = try await self.checkVerified(result)
                    
                    // ⚠️ 注意：消耗型商品 (Consumable) 也会在这里回调
                    // 必须确保逻辑幂等，不要重复发金币
                    await self.updatePurchasedStatus(transaction)
                    
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
        var purchasedIds: Set<String> = []
        
        // 遍历用户当前的 entitlements (即所有有效的、未退款的交易) 只包含：非消耗型 + 有效的订阅
        // 不包含：消耗型 (金币)、已过期的订阅、已退款的交易
        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)
                
                // 标记为已购买
                purchasedIds.insert(transaction.productID)
                
                // 如果是订阅，顺便检查下详细状态（是否取消了自动续费等）
                if transaction.productType == .autoRenewable {
                    await checkSubscriptionDetails(transaction)
                }
            } catch {
                log("权益验证失败: \(error)")
            }
        }
        
        self.purchasedProductIDs = purchasedIds
        log("当前有效权益: \(purchasedIds.joined(separator: ", "))")
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
    
    // 更新本地状态 (发货)
    @MainActor
    private func updatePurchasedStatus(_ transaction: Transaction) async {
        if transaction.productType == .consumable {
            // 消耗型逻辑：加金币
            // ⚠️ 真实项目中，这里应该把 transactionID 发给服务器做校验，由服务器加币
            // 本地简单的防重处理可以基于 transaction.id
            coinBalance += 100
            log("消耗型商品到账，金币 +100，交易 ID: \(transaction.id)")
        } else {
            // 非消耗型 / 订阅
            if transaction.revocationDate == nil {
                // 正常购买
                purchasedProductIDs.insert(transaction.productID)
                log("已激活商品: \(transaction.productID)")
                if transaction.productType == .autoRenewable {
                    await checkSubscriptionDetails(transaction)
                }
            } else {
                // 被退款/撤销了
                purchasedProductIDs.remove(transaction.productID)
                subscriptionStatus = "已退款/撤销"
                log("交易已撤销: \(transaction.productID)")
            }
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
}
