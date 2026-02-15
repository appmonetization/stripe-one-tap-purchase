// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "StripeOneTapPurchase",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "StripeOneTapPurchase",
            targets: ["StripeOneTapPurchase"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/cloudcaptainai/helium-swift", from: "4.1.3"),
        .package(url: "https://github.com/stripe/stripe-ios-spm", from: "25.6.2"),
    ],
    targets: [
        .target(
            name: "StripeOneTapPurchase",
            dependencies: [
                .product(name: "Helium", package: "helium-swift"),
                .product(name: "StripeApplePay", package: "stripe-ios-spm"),
            ]
        ),
    ]
)
