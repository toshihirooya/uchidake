import StoreKit
import SwiftUI

/// 購入画面から開く、規約などのリンク先。
enum LegalLinks {
    /// Apple の標準の利用規約（EULA）
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    /// プライバシーポリシー。ページはこのリポジトリの site/（Firebase Hosting）。アプリの表示言語に合わせる
    static var privacy: URL { privacy(language: Bundle.main.preferredLocalizations.first) }

    static func privacy(language: String?) -> URL {
        URL(string: language == "ja"
            ? "https://uchidake-camera.web.app/privacy"
            : "https://uchidake-camera.web.app/en/privacy")!
    }
}

/// 家族プランの購入画面。カメラにする端末でも、見る側の端末でも開ける。
struct FamilyPlanView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var notice: LocalizedStringKey?
    @State private var managingSubscriptions = false
    /// 月額・年額の人が、この画面で買い切りを買った（サブスクは自動では止まらない）
    @State private var boughtLifetimeOverSubscription = false

    private var plan: FamilyPlanStore { model.plan }

    /// 購入画面に並べる商品。買い切りの人には何も出さず、月額・年額の人には買い切りだけ出す。
    static func offered(for record: PlanRecord?, isActive: Bool) -> [PlanProduct] {
        guard isActive, let record else { return [.monthly, .yearly, .lifetime] }
        return record.product == .lifetime ? [] : [.lifetime]
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if plan.isActive {
                        activeCard
                    }
                    offers
                    notes
                    Button("閉じる") { dismiss() }
                        .frame(maxWidth: .infinity)
                        .tint(.secondary)
                }
                .frame(maxWidth: 440)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .task { await plan.loadProducts() }
        .manageSubscriptionsSheet(isPresented: $managingSubscriptions)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 34))
                .foregroundStyle(Theme.accent)
            Text("家族プラン")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Label("1 台のカメラを、同時に 4 台まで見られます（無料は 1 台）", systemImage: "eye.fill")
            Label("カメラを 2 台以上使えます（無料は 1 台）", systemImage: "video.fill")
        }
        .font(.callout)
    }

    private var activeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("家族プランが有効です", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(Theme.accent)
            if let record = plan.record {
                Text(Self.name(of: record.product))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if boughtLifetimeOverSubscription {
                Text("買い切りを購入しました。月額・年額は自動では止まらないので、「サブスクリプションを管理」から解約してください。")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
            }
            if boughtLifetimeOverSubscription || (plan.record?.expires != nil) {
                Button("サブスクリプションを管理") {
                    managingSubscriptions = true
                }
                .font(.callout)
                .tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var offers: some View {
        let offered = Self.offered(for: plan.record, isActive: plan.isActive)
        if !offered.isEmpty {
            switch plan.catalog {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            case .unavailable:
                VStack(alignment: .leading, spacing: 10) {
                    Text("商品を読み込めませんでした。通信を確かめて、もう一度試してください。")
                        .font(.footnote)
                        .foregroundStyle(Theme.warning)
                    Button("もう一度試す") {
                        Task { await plan.loadProducts() }
                    }
                    .tint(Theme.accent)
                }
            case .ready:
                VStack(spacing: 10) {
                    ForEach(offered, id: \.self) { kind in
                        if let offer = plan.offers.first(where: { $0.kind == kind }) {
                            offerButton(offer)
                        }
                    }
                }
                .disabled(busy)
            }
            if let notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
            }
        }
    }

    private func offerButton(_ offer: FamilyPlanStore.Offer) -> some View {
        let kind = offer.kind
        return Button {
            buy(kind)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.name(of: kind))
                        .font(.headline)
                    if kind == .monthly, plan.monthlyTrialAvailable {
                        Text("最初の 7 日間は無料")
                            .font(.footnote)
                    } else if kind == .lifetime {
                        Text("一度の支払いで、ずっと使えます")
                            .font(.footnote)
                    }
                }
                Spacer()
                Text(Self.price(of: offer))
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(kind == .monthly ? Theme.accent : Theme.panel)
        .foregroundStyle(kind == .monthly ? .black : .white)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("家族プランは、カメラにする端末で有効にします。カメラの端末で、購入した Apple Account（またはファミリー共有の家族）でサインインして、「購入を復元」を押してください。")
            Button("購入を復元") {
                restore()
            }
            .font(.callout)
            .tint(Theme.accent)
            .disabled(busy)
            Text("買い切りで使えるのは、家の中で使う機能です。今後、外出先から見る機能を足す場合は、別の月額プランになります。")
            Text("月額・年額は、期間が終わる 24 時間前までに解約しないかぎり、自動で更新されます。解約は、設定アプリの Apple Account の「サブスクリプション」からできます。")
            HStack(spacing: 20) {
                Link("利用規約", destination: LegalLinks.terms)
                Link("プライバシーポリシー", destination: LegalLinks.privacy)
            }
            .tint(Theme.accent)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func buy(_ kind: PlanProduct) {
        let hadSubscription = plan.isActive && plan.record?.expires != nil
        busy = true
        notice = nil
        Task {
            let outcome = await plan.purchase(kind)
            busy = false
            switch outcome {
            case .purchased:
                if kind == .lifetime, hadSubscription {
                    boughtLifetimeOverSubscription = true
                }
            case .pending:
                notice = "承認を待っています。承認されると、自動で有効になります。"
            case .failed:
                notice = "購入できませんでした。もう一度試してください。"
            case .cancelled:
                break
            }
        }
    }

    private func restore() {
        busy = true
        notice = nil
        Task {
            let restored = await plan.restore()
            busy = false
            if !restored {
                notice = "購入が見つかりませんでした。"
            }
        }
    }

    private static func name(of kind: PlanProduct) -> LocalizedStringKey {
        switch kind {
        case .monthly: "月額"
        case .yearly: "年額"
        case .lifetime: "買い切り"
        }
    }

    /// 金額は App Store の表示をそのまま使う（文言には書かない）。
    private static func price(of offer: FamilyPlanStore.Offer) -> LocalizedStringKey {
        switch offer.kind {
        case .monthly: "\(offer.price)／月"
        case .yearly: "\(offer.price)／年"
        case .lifetime: "\(offer.price)"
        }
    }
}

/// カメラを始められないときの画面。同じ組で、家族プランの無いカメラがすでに動いている。
struct CameraBlockedView: View {
    /// すでに動いているカメラの名前
    let otherName: String
    @Environment(AppModel.self) private var model
    @State private var showingPlan = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.warning)
            Text("この家では、すでに「\(otherName)」がカメラとして動いています。カメラを 2 台以上使うには、家族プランが必要です。")
                .font(.callout)
                .multilineTextAlignment(.center)
            Button {
                showingPlan = true
            } label: {
                Text("家族プランを見る")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .foregroundStyle(.black)
            Button("戻る") {
                model.backHome()
            }
            .tint(.white)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 440)
        .padding(24)
        .sheet(isPresented: $showingPlan) {
            FamilyPlanView()
        }
    }
}
