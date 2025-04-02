//
//  RevenueCatAdaptor.swift
//  TAPurchaseAdaptorRevenueCat
//
//  Created by Robert Tataru on 28.03.2025.
//

import Foundation
import TAPurchase
import Combine
import RevenueCat

public struct TAPurchaseAdaptorRevenueCat: TAPurchaseAdaptorProtocol {

    enum PurchaseError: LocalizedError {
        case productNotFound
        case userCancelledPurchase
    }

    public var grantedEntitlementsUpdatePublisher: AnyPublisher<[TAGrantedEntitlement], Never>

    private let entitlementsSubject = PassthroughSubject<[TAGrantedEntitlement], Never>()
    private var cancellables = Set<AnyCancellable>()

    public init(apiKey: String) {
        self.grantedEntitlementsUpdatePublisher = entitlementsSubject.eraseToAnyPublisher()
        
        Purchases.configure(withAPIKey: apiKey)
        Purchases.logLevel = .debug
        start()
    }
    
    private func start() {
        Task {
            for await customerInfo in Purchases.shared.customerInfoStream {
                let entitlements = customerInfo.entitlements.active.map {
                    TAGrantedEntitlement(
                        id: $0.value.identifier,
                        productID: $0.value.productIdentifier,
                        latestPurchaseDate: $0.value.latestPurchaseDate,
                        originalPurchaseDate: $0.value.originalPurchaseDate,
                        expirationDate: $0.value.expirationDate,
                        isActive: $0.value.isActive
                    )
                }
                entitlementsSubject.send(entitlements)
            }
        }
    }

    /// Purchases a product with the given identifier using the current offering.
    /// - Parameter productID: The identifier of the product to purchase.
    /// - Returns: An array of granted entitlements after the purchase completes.
    /// - Throws: An error if the product is not found or the purchase fails.
    public func purchaseProduct(productID: String) async throws -> [TAGrantedEntitlement] {
        let offerings = try await Purchases.shared.offerings()
        guard let package = offerings.current?.availablePackages.first(where: { $0.storeProduct.productIdentifier == productID }) else {
            throw PurchaseError.productNotFound
        }

        let result = try await Purchases.shared.purchase(package: package)

        if result.userCancelled {
            throw PurchaseError.userCancelledPurchase
        }

        return try await getGrantedEntitlements()
    }

    /// Restores previously purchased products and returns the associated entitlements.
    /// - Returns: An array of granted entitlements.
    /// - Throws: An error if restoring purchases fails.
    public func restorePurchase() async throws -> [TAGrantedEntitlement] {
        _ = try await Purchases.shared.restorePurchases()
        return try await getGrantedEntitlements()
    }

    /// Retrieves the currently active entitlements for the user.
    /// - Returns: An array of currently active granted entitlements.
    /// - Throws: An error if entitlements cannot be fetched.
    public func getGrantedEntitlements() async throws -> [TAGrantedEntitlement] {
        let customerInfo = try await Purchases.shared.customerInfo()
        return customerInfo.entitlements.active.map {
            TAGrantedEntitlement(
                id: $0.value.identifier,
                productID: $0.value.productIdentifier,
                latestPurchaseDate: $0.value.latestPurchaseDate,
                originalPurchaseDate: $0.value.originalPurchaseDate,
                expirationDate: $0.value.expirationDate,
                isActive: $0.value.isActive
            )
        }
    }
    
    /// Checks if the specified product is eligible for a trial or introductory offer.
    /// - Parameter productID: The identifier of the product to check.
    /// - Returns: `true` if the product has an introductory discount available; otherwise, `false`.
    /// - Throws: An error if the product is not found.
    public func checkTrialEligibility(productID: String) async throws -> Bool {
        let offerings = try await Purchases.shared.offerings()
        
        guard let product = offerings.current?.availablePackages
            .map(\.storeProduct)
            .first(where: { $0.productIdentifier == productID }) else {
            throw PurchaseError.productNotFound
        }

        return product.introductoryDiscount != nil
    }
    
    /// Retrieves a list of products with their trial eligibility status.
    /// - Parameter productIDs: A list of product identifiers to retrieve.
    /// - Returns: A list of `TAProduct` instances corresponding to the input identifiers.
    /// - Throws: An error if the products cannot be fetched or trial eligibility cannot be determined.
    public func getProducts(for productIDs: [String]) async throws -> [TAProduct] {
        let offerings = try await Purchases.shared.offerings()
        let storeProducts = offerings.current?.availablePackages
            .map(\.storeProduct)
            .filter { productIDs.contains($0.productIdentifier) } ?? []

        return try await withThrowingTaskGroup(of: TAProduct.self) { group in
            for storeProduct in storeProducts {
                guard let sk2Product = storeProduct.sk2Product else { continue }

                group.addTask {
                    return TAProduct(storeKitProduct: sk2Product)
                }
            }

            var products: [TAProduct] = []
            for try await product in group {
                products.append(product)
            }

            return products
        }
    }
}
