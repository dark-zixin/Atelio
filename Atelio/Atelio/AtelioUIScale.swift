import SwiftUI

/// 把 `AtelioConfig.fontSize` 包成 SwiftUI 可觀察的字體縮放來源。
///
/// app 只有單一字體旋鈕（`AtelioConfig.fontSize`，預設 13pt，原本供終端機字體）。
/// 為了讓說明類 UI（`SkillSetupSheet` / `HelpView`）跟使用者的字體偏好一致，這裡
/// 把各語意角色的字級基準乘上「當前字體 / 預設字體」的倍率：
/// - 倍率 = 1（字體 = 13pt）時，外觀與系統語意字級完全相同。
/// - 使用者用 ⌘± 調大字體 → 監聽 `.atelioFontSizeChanged` 即時放大說明文字。
///
/// 只縮放文字內容，不動原生控制元件（按鈕）的尺寸，維持系統一致的控制元件外觀。
@Observable
@MainActor
final class AtelioUIScale {
    private(set) var fontSize: CGFloat = AtelioConfig.fontSize

    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        // queue: .main 保證 callback 在主執行緒，assumeIsolated 向並發檢查器
        // 點明此事，安全地在 main actor 上更新 fontSize。
        observer = NotificationCenter.default.addObserver(
            forName: .atelioFontSizeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fontSize = AtelioConfig.fontSize
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 相對預設字體（13pt）的縮放倍率
    private var factor: CGFloat { fontSize / AtelioConfig.fontSizeDefault }

    /// 依語意角色回傳縮放後的字型，保留各角色原本的字重與設計。
    func font(_ role: Role) -> Font {
        .system(size: role.baseSize * factor, weight: role.weight, design: role.design)
    }

    /// 把固定尺寸（如欄寬）依同一倍率縮放，維持版面比例不被放大的字截斷。
    func scaled(_ value: CGFloat) -> CGFloat { value * factor }

    /// UI 文字的語意角色，基準採 macOS 預設 Dynamic Type 字級（pt）。
    enum Role {
        case largeTitle, title2, headline, body, callout, subheadline, footnote, caption
        case monoBody, monoCallout

        var baseSize: CGFloat {
            switch self {
            case .largeTitle: return 26
            case .title2: return 17
            case .headline: return 13
            case .body: return 13
            case .callout: return 12
            case .subheadline: return 11
            case .footnote: return 10
            case .caption: return 10
            case .monoBody: return 13
            case .monoCallout: return 12
            }
        }

        /// headline 預設即 semibold，其餘維持 regular（需要更重的由呼叫端 `.fontWeight` 覆寫）。
        var weight: Font.Weight {
            self == .headline ? .semibold : .regular
        }

        var design: Font.Design {
            switch self {
            case .monoBody, .monoCallout: return .monospaced
            default: return .default
            }
        }
    }
}
