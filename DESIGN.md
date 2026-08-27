# DESIGN.md — Clipy Apple Silicon リライト設計

> 対象読者: このリポジトリで作業する開発者 / automation。セキュリティ要件は [security-guidance.md](security-guidance.md)。運用ルールは [AGENTS.md](AGENTS.md)。
>
> 本書の技術記述は 2026-05 時点の各公式ドキュメント・一次情報に基づき検証済み。API 名・バージョン依存箇所は実装時に対象 SDK で再確認すること（特に SwiftUI/AppKit と SQLiteData 1.6.x、新 pasteboard プライバシー API）。

## 1. 目的とスコープ
Clipy（macOS 用クリップボードマネージャ、ClipMenu の後継）を **Apple Silicon ネイティブ**・**SwiftUI 中心**・**SQLiteData 永続化**・**macOS 14+**・**Swift 6** で作り直す。機能パリティ（履歴・スニペット・ホットキー・貼り付け・除外アプリ・スクショ取り込み・自動更新）を保ちつつ、レガシースタック（Realm / RxSwift / XIB / PINCache / NSCoding / LoginServiceKit）を一掃し、セキュリティを大幅強化する。

## 2. 確定事項

| 項目 | 決定 | 根拠 |
| --- | --- | --- |
| UI フレームワーク | SwiftUI App ライフサイクル + AppKit コア | MenuBarExtra 単独では Clipy のメニュー UX を再現不可（§4.2） |
| 永続化 | SQLiteData / GRDB（pointfreeco） | オリジナルが移行中。値型・ライブクエリ・SQL 移行制御・macOS 14 未満も射程 |
| 最低 OS | macOS 14 Sonoma | Observation/`@Observable` ネイティブ、swift-perception 不要 |
| アーキ | arm64 + x86_64 ユニバーサル | `ARCHS_STANDARD`、Release は `ONLY_ACTIVE_ARCH=NO` |
| 配布 | Developer ID + notarization、Hardened Runtime 有効、**App Sandbox 無し** | Accessibility/CGEvent は sandbox 非対応（§11） |
| 言語モード | Swift 6 + strict concurrency `complete` | 段階導入（§6） |

## 3. オリジナル Clipy の現状（サブシステム別要約）

オリジナルは **AppKit + XIB + AppDelegate** 構成。**Realm → SQLiteData の移行が途中**（スニペットは SQLiteData 済み、履歴はまだ Realm）。主要点:

- **メニュー（`MenuManager`）**: `NSStatusItem` と 3 つの `NSMenu`（clip/history/snippet）をコードで構築。ホットキーで `menu.popUp(at: NSEvent.mouseLocation)`（カーソル位置）。数字キー equivalents（0–9）、フォルダ＝サブメニュー、ツールチップ、テンプレートアイコン、PINCache 非同期サムネイル、インライン/フォルダ内配置の切替。データ/設定変更で全 `NSMenu` を再構築（13+ の UserDefaults を Rx 監視、1s throttle）。
- **キャプチャ（`ClipService`）**: `NSPasteboard.general.changeCount` を **0.75ms（`.microseconds(750)`、ms の誤記の可能性）で busy-poll**。`CPYClipData` を作り、`NSKeyedArchiver.archiveRootObject(_:toFile:)` で `<UUID>.data` に**平文保存**、サムネイルは PINCache。dedupe ハッシュは `String.hash`（プロセス毎に乱数シード=不安定）XOR `Data.count`（弱い）で、衝突・非再現の懸念。
- **入力（`PasteService`/`HotKeyService`/`AccessibilityService`/`ExcludeAppService`）**: Magnet でグローバルホットキー、Sauce でレイアウト非依存キーコード、`CGEvent` で Cmd+V 注入（Accessibility 必須）。除外アプリは前面アプリ判定＋1Password owner type のみ（しかもユーザーが除外リストに追加した時だけ）。`org.nspasteboard.*` マーカーは**未対応**。
- **設定/スニペット**: XIB の 7 ペイン（General/Menu/Type/ExcludeApp/Shortcuts/Updates/Beta）が UserDefaults に Cocoa Bindings 直結。スニペット編集は `NSOutlineView` + SQLiteData（`SnippetRepository`）、AEXML で XML 入出力。
- **永続化/DI**: `AppEnvironment.current`（レガシー static）と swift-dependencies の二重 DI。履歴用 SQLite テーブル（`pasteboardHistories`/assets/thumbnail）は V1 マイグレーションで作成済みだが**未使用**。Realm→SQLite の**データ移行は未実装**。
- **配布/更新**: Developer ID、`LSUIElement=true`。Sparkle 2.9.2（EdDSA `SUPublicEDKey`）。Info.plist にレガシー DSA key（`SUPublicDSAKeyFile`）が残るが Sparkle 2 は無視（実害無し＝除去のみ）。**Hardened Runtime / entitlements は未設定**（このままでは notarization 不可）。

主要なリスク（リライトで解消すべきもの）: 全 NSMenu の毎回再構築による負荷、不安定な dedupe ハッシュ、平文保存、非セキュア unarchive、Realm スレッド拘束 + `try!`、データ移行の欠如。

## 4. ターゲットアーキテクチャ

### 4.1 レイヤと App ライフサイクル
SwiftUI App ライフサイクルを採用しつつ、AppKit でしか実現できない部分を `@NSApplicationDelegateAdaptor` 配下の `AppDelegate` に集約する。

```
ClipyApp (@main, SwiftUI App)
├─ @NSApplicationDelegateAdaptor(AppDelegate.self)   ← AppKit コア
│   ├─ NSApp.setActivationPolicy(.accessory)         ← LSUIElement と二重に agent 化
│   ├─ NSStatusItem + StatusMenuController (NSMenu 構築)
│   ├─ PasteboardMonitor (changeCount ポーリング → capture)
│   ├─ HotKeyCenter 登録 (Magnet)  → メニュー/パネル起動
│   ├─ FloatingPanel (非アクティブ化 NSPanel + NSHostingView)
│   ├─ ScreenshotObserver (Screeen)
│   └─ Sparkle SPUStandardUpdaterController (+ Gentle Reminders)
├─ Settings { SettingsRootView() }                   ← SwiftUI 設定画面
└─ Window("snippets", ...) { SnippetEditorView() }   ← SwiftUI スニペットエディタ（任意・hidden helper も兼ねる）
```

- ドメイン層は `@Observable`（Observation, macOS 14+）モデル + repository。`.environment(_:)` で注入、`@Environment` / `@Bindable` で参照。`ObservableObject`/`@Published` は使わない。
- 並行性: AppKit/UI は `@MainActor`、pasteboard 監視やファイル I/O は `actor`。RxSwift は全廃し async/await・`AsyncStream`・swift-sharing に置換。

### 4.2 メニュー / ポップアップ UI 戦略（最重要の設計判断）
**MenuBarExtra 単独では Clipy のコア UX を再現できない**（検証済み）。理由:
- `.menu` スタイルは画像・カスタムレイアウト不可、かつ**開いた時に body を再描画しない**（FB13683957）ため、ライブな履歴一覧に不適。
- `.window` スタイルは任意 SwiftUI を描けるが、ネイティブサブメニュー・メニュー内数字キー equivalents・カーソル位置ポップアップ・右クリックが無い。
- MenuBarExtra は `NSStatusItem` / ポップアップ `NSWindow` へのアクセス API を持たず、**プログラムからの任意座標ポップアップができない**。

→ **採用方針（二面 UI）**:
1. **NSMenu（AppKit 維持）**: ホットキー起動のカーソル位置ポップアップ、フォルダ＝サブメニュー、数字キー equivalents（0–9）、ツールチップ、テンプレートアイコン。`StatusMenuController` が `@Observable` モデルから `menuNeedsUpdate(_:)` で都度構築（全再構築ではなく差分/遅延構築）。リッチ行が要る場合は `NSHostingMenu` / `NSMenuItem.view = NSHostingView` で SwiftUI 行を埋め込む。
2. **FloatingPanel（非アクティブ化 NSPanel）**: 検索付きのリッチ履歴ブラウザ。`styleMask: [.nonactivatingPanel]`（前面アプリのフォーカスを奪わない＝貼り付け先を保持）、`level = .floating`、`becomesKeyOnlyIfNeeded = true`、`hidesOnDeactivate = true`、`NSEvent.mouseLocation` に配置、外側クリックの global monitor で閉じる。中身は `NSHostingView` で SwiftUI。

> **as-built（2026-06-09 で上記を更新）**: 履歴・スニペット・管理操作は**単一の統合 FloatingPanel に集約**し、NSMenu による履歴/スニペット描画は撤去した（数字キー・検索・カテゴリフィルタ・リッチプレビューはパネル側で実現。ステータスアイテム右クリックのフォールバック NSMenu のみ残存）。MenuBarExtra 不採用の判断自体は変わらない。

> `NSEvent.mouseLocation` は画面座標（左下原点）。`setFrameTopLeftPoint` も同座標系。マルチディスプレイ/Retina の座標変換に注意。

### 4.3 永続化（SQLiteData / GRDB）
- **単一 writer**。read 多めなので `DatabasePool`（WAL）を推奨。`defaultDatabase(configuration:)` ヘルパで preview/test 時は隔離 DB。
- スキーマは `@Table` 値型。`DatabaseMigrator` に **生 SQL（`#sql`）の named migration** を登録（出荷後は編集せず追加のみ）。`STRICT` テーブル、FK `ON DELETE CASCADE`、`#if DEBUG` で `eraseDatabaseOnSchemaChange`。
- ライブクエリは `@FetchAll` / `@FetchOne`（`@Observable` モデル内では `@ObservationIgnored` を付与）。検索は `.task(id:)` 内で `$items.load(.fetchAll(...))`。
- **全 write は repository 経由**（`@Dependency(\.defaultDatabase)` を読み `database.write { db in ... }`）。テストは `.dependency(\.defaultDatabase, ...)` で in-memory 注入。

スキーマ（履歴メタは DB、本体ペイロードは暗号化 blob ファイル）。**`title` はコピー内容のプレビュー＝機微情報**なので **暗号化 BLOB（`titleCipher`）** に変更し、dedupe は **HMAC-SHA256(鍵, ペイロード)** とする（spike で SQLCipher 不採用＝フィールド暗号化採用。R3。§security-guidance §5）。テーブル名は `@Table` マクロ既定の複数形（`@Table("clips")` 等で明示固定。原版 SQLiteData 移行とも一致）。as-built（commit `e8673be`）:

```sql
CREATE TABLE "clips"(
  "id"            TEXT NOT NULL PRIMARY KEY,   -- UUID
  "contentHash"   TEXT NOT NULL,               -- HMAC-SHA256 hex = dedupe キー（鍵付き計算は capture）
  "titleCipher"   BLOB NOT NULL,               -- 表示用プレビューの AES-GCM 暗号文（表示時に復号）
  "primaryType"   TEXT NOT NULL,               -- UTType 識別子
  "createdAt"     INTEGER NOT NULL,            -- unix 秒（Date.UnixTimeRepresentation。素の Date は TEXT bind で STRICT 不適合）
  "isPinned"      INTEGER NOT NULL DEFAULT 0,
  "isColorCode"   INTEGER NOT NULL DEFAULT 0,
  "dataPath"      TEXT NOT NULL,               -- 暗号化 blob への相対パス
  "thumbnailID"   TEXT,
  "sourceBundle"  TEXT                          -- org.nspasteboard.source 由来
) STRICT;
-- 非 UNIQUE: FR-CAP-5 が設定で重複挙動を変える（overwriteSameHistory=false は重複行を許容）ため、
-- 重複排除はスキーマ制約ではなく ClipRepository.ingest のポリシー。索引は dedupe 照会の高速化用。
CREATE INDEX "clips_contentHash" ON "clips"("contentHash");
CREATE INDEX "clips_createdAt" ON "clips"("createdAt" DESC);

CREATE TABLE "clipRepresentations"(
  "clipID"   TEXT NOT NULL REFERENCES "clips"("id") ON DELETE CASCADE,
  "uttype"   TEXT NOT NULL,
  "byteSize" INTEGER NOT NULL,
  PRIMARY KEY ("clipID","uttype")
) STRICT;

CREATE TABLE "snippetFolders"(
  "id" TEXT NOT NULL PRIMARY KEY, "title" TEXT NOT NULL,
  "sortOrder" INTEGER NOT NULL DEFAULT 0, "isEnabled" INTEGER NOT NULL DEFAULT 1
) STRICT;
CREATE TABLE "snippets"(
  "id" TEXT NOT NULL PRIMARY KEY,
  "folderID" TEXT NOT NULL REFERENCES "snippetFolders"("id") ON DELETE CASCADE,  -- 元コードは cascade 欠落→必須
  "title" TEXT NOT NULL, "content" TEXT NOT NULL,
  "sortOrder" INTEGER NOT NULL DEFAULT 0, "isEnabled" INTEGER NOT NULL DEFAULT 1
) STRICT;
CREATE INDEX "snippets_folderID" ON "snippets"("folderID");

CREATE TABLE "excludedApps"(                    -- 旧 UserDefaults excludeApplications を DB 化
  "bundleIdentifier" TEXT NOT NULL PRIMARY KEY,
  "name"             TEXT NOT NULL
) STRICT;
```

`@Table` 値型と repository（抜粋）:

```swift
@Table("clips") struct Clip: Identifiable, Sendable {
  let id: UUID
  var contentHash: String
  var titleCipher: Data            // 表示用プレビューの AES-GCM 暗号文
  var primaryType: String
  @Column(as: Date.UnixTimeRepresentation.self) var createdAt: Date  // INTEGER（unix 秒）bind
  var isPinned = false
  var isColorCode = false
  var dataPath: String
  var thumbnailID: String?
  var sourceBundle: String?
}

struct ClipRepository {            // 全 write はここに集約。テストで差し替え可能
  @Dependency(\.defaultDatabase) private var database
  func add(_ clip: Clip) throws { try database.write { try Clip.insert { clip }.execute($0) } }
  func delete(id: Clip.ID) throws { try database.write { try Clip.delete().where { $0.id.eq(id) }.execute($0) } }
  // dedupe（copySameHistory/overwriteSameHistory）と履歴上限 trim は ingest()/trim() に実装。
}
```

> SQLiteData 1.6.0 で Swift 6.3 / Xcode 26.4 対応のため StructuredQueries API に破壊的変更あり。`.upToNextMinor(from: "1.6.2")` でピンし、0.31 移行ガイドを確認。クエリビルダのメソッド名は対象バージョンでコンパイル確認すること。

### 4.4 キャプチャパイプライン
1. `actor PasteboardMonitor` が `NSPasteboard.general.changeCount` を**200–500ms 間隔**でポーリング（macOS に変更通知は無い。0.75ms の busy-poll は廃止）。
2. 変更検出時、まず **プライバシーマーカー判定**（§security-guidance）。`Concealed`/`Transient` は破棄、`AutoGenerated` は記録しない（必要なら「現在値」表示のみ）。新 OS では `detectPatterns/detectMetadata`（content を読まない）で先に種別判定。
3. 自前の貼り付け書込みは、書込み直後の changeCount を skip 集合に入れて自己捕捉を防ぐ（旧 `incrementChangeCount()` の置換）。
4. content 読取は off-main の `actor` で `Sendable` な `ClipSnapshot` を構築（UTType ベース、`readObjects(forClasses:options:)`）。dedupe は **SHA-256**（CryptoKit）で安定キー。
5. ペイロードは暗号化 blob として保存し、メタデータ行を `database.write{}` で挿入。**機微列（`title`）は暗号化 BLOB、dedupe は鍵付き HMAC**（SQLCipher は不採用＝フィールド暗号化。§security-guidance §5 / R3）。
6. retention/GC は `AsyncTimerSequence` の構造化タスクで 1 トランザクション（`maxHistorySize` 超過行を削除→cascade→blob ファイル削除）。

### 4.5 入力系（維持しつつ近代化）
- **Magnet / Sauce / KeyHolder / Screeen は維持**（Clipy 自身の保守ライブラリで代替不在。特に Sauce は非 QWERTY 配列に必須）。KeyHolder の `RecordView`（NSView）は `NSViewRepresentable` で SwiftUI 設定画面に埋め込む。
- ホットキー所有は `@Observable` モデル / swift-dependencies へ。ハンドラはクロージャ。スニペットフォルダ用ホットキーは DB（`snippetFolder` 行）側へ寄せ、`folderKeyCombos` の UserDefaults blob を廃止（フォルダ削除時のホットキー解除ライフサイクルを DB と同期）。
- **貼り付けは CGEvent Cmd+V をほぼそのまま維持**（`.combinedSessionState` + suppression）。`PasteService` を `Sendable` 依存に。post は main で。Sauce で 'v' キーコード解決。
- Accessibility ゲート（`AXIsProcessTrustedWithOptions`）維持。macOS 10.14 分岐は削除（14+）。**ハードニング**: 貼り付け先アプリを事前に記録し、post 直前に frontmost が一致するか検証（不一致なら beep して中止）。
- 除外アプリ/`CPYAppInfo` は SQLite テーブル + `Codable`/`Sendable` 構造体へ移行（`NSCoding` 廃止）。前面アプリ追跡は `NSWorkspace.didActivateApplicationNotification` の `AsyncStream`、または capture 時に `frontmostApplication` を直読み。
- ログイン項目は **`SMAppService.mainApp`**（`register()`/`unregister()`/`.status`）。`.requiresApproval` を UI に反映。LoginServiceKit 廃止。

### 4.6 設定画面（SwiftUI Settings scene）
`Settings { SettingsRootView() }` にカスタムタブバー（SF Symbol アイコンのみ）、現行ペイン = General / Menu / Type / ExcludedApps / Shortcuts / Privacy / Diagnostics（Beta は廃止し General に統合、Updates は独立した About ウィンドウへ移動）。設定値は `@AppStorage`（または swift-sharing `@Shared(.appStorage)`）。**UserDefaults のキー名・数値型はオリジナル互換を維持**（後方互換のため。例: status item style と更新間隔は数値で保存）。Type ペインの「閉じる時保存」隠し副作用は廃止し明示保存。

> accessory アプリでの設定オープンは不安定なため: メニュー/ホットキー → `NotificationCenter` → 一時的に `setActivationPolicy(.regular)` + `activate` → `openSettings()`（hidden helper window を Settings scene より**前**に宣言）→ 閉じたら `.accessory` に戻す。

### 4.7 スニペット
`NSOutlineView` → SwiftUI `List(selection:)` + `DisclosureGroup`、`NavigationSplitView`（左: フォルダ/スニペット木、右: 内容 `TextEditor`）。`@FetchAll` でライブ観測。変更は `SnippetRepository` 経由、`.onMove` で並べ替え。**AEXML 入出力ロジックは維持**（`.fileImporter`/`.fileExporter`、要素名・既定値はファイル互換のため保持）。`deleteFolder` の子スニペット未削除バグは FK cascade で解消。

### 4.8 自動更新（Sparkle 2.x）
- **EdDSA（Ed25519）のみ**。`./bin/generate_keys`（秘密鍵は Keychain、git に入れない）→ `SUPublicEDKey` を Info.plist へ。**レガシー DSA（`SUPublicDSAKeyFile` / `dsa_pub.pem`）は削除**（Sparkle 2 は未使用）。
- `SUFeedURL` は HTTPS。`./bin/generate_appcast ./updates/` で appcast 生成（署名は手編集しない）。実値: `SUPublicEDKey` は本物の公開鍵、`SUFeedURL` = `https://github.com/ClipySi/clipy-si-macos/releases/latest/download/appcast.xml`（appcast はリリースアセットとして公開）。
- agent アプリなので **`SPUStandardUpdaterController` + Gentle Reminders**（`SPUStandardUserDriverDelegate`）で Dock バッジ + 通知センター提示。

### 4.9 機密マスキング / 共有 Rust コア（実装済み）
コピー内容に紛れ込む **秘密（パスワード / API キー / トークン）を履歴の表示時に伏字化**する追加防御。保存時暗号化（§4.3）や privacy marker 尊重（§4.4）を**置換せず**上乗せする。検出/マスクの判定ロジックはクロスプラットフォームで共有するため、**単一の Rust 実装 `clipy-si-core` に集約**し、macOS には **UniFFI 経由で静的リンク**する（OS ごとの正規表現/エントロピー差を原理的に消す）。core 実装は公開リポジトリ [ClipySi/clipy-si-core](https://github.com/ClipySi/clipy-si-core) で管理する（リリースアプリにはビルド済み XCFramework として静的リンク）。

- **Rust コア（[ClipySi/clipy-si-core](https://github.com/ClipySi/clipy-si-core)）**: `crates/clipy-si-core`＝純ロジック（`detect_secrets`/`is_secret`/`mask`・無 I/O・無ログ・`forbid(unsafe_code)`）+ 言語非依存 KAT（`kat/redaction.json`）。`crates/clipy-si-core-ffi`＝UniFFI ラッパ（unsafe な生成 scaffolding をここに隔離）。
- **配布**: core リポジトリのタグ駆動 CI が arm64+x86_64 の **静的ライブラリ XCFramework**（`ClipySiCoreFFI`）をビルドし、**core リポジトリの GitHub Release アセット**として build-provenance attestation 付きで公開（v0.3.0 以降。core-v0.2.0 以前は本リポジトリの Release アセット）。`core/ClipySiCore` の SPM パッケージが `binaryTarget(url:checksum:)` で取得し `Clipy.xcodeproj` がリンクする（ローカル開発ではパッケージ直下に置いた XCFramework を自動使用）。静的リンクのため**別途署名する framework が存在せず、`disable-library-validation` も不要**（ad-hoc 署名 + Hardened Runtime で `codesign --verify --strict` 通過を実証）。生成 Swift グルーはコミットし、XCFramework 本体は git-ignore。
- **macOS 統合（薄殻）**: `MaskingService`（`\.maskingService` 依存・live は UniFFI を呼ぶだけ・test/preview は identity）。単一フック点 = `ClipDisplayBuilder.display(of:)`（復号直後）で `ClipDisplay` に **生 `title`（reveal 用・描画禁止）/ `displayTitle`（描画用・マスク済）/ `isSecret`** を持たせる。メニュー title・**ツールチップ**・履歴マネージャ Table が `displayTitle` を描画。データ操作（コピー/スニペット化/エクスポート/ペースト）は DB ペイロードを再読込するため**マスクは表示専用で内容を破壊しない**。
- **任意 LocalAuth**: `AuthGate`（`.deviceOwnerAuthentication`・`AccessibilityService` 同形の注入サービス）を、`requireAuthForSecretReveal` ON 時にメニューの機密項目 paste 直前に挟む。Touch ID/パスワード未設定時は fail-open（保護不能なので許可）し、Privacy ペインで警告。
- **設定**: `DefaultsKeys` に `maskSecretsInMenu`（既定 ON）/ `maskStyle`（既定 full）/ `requireAuthForSecretReveal`。Settings に **Privacy ペイン**新設（13 ロケール i18n）。
- **位置づけ**: 本フェーズで **Rust → Swift → 署名済み .app のパイプライン**を確立し、暗号・同期コアを同じ `clipy-si-core` へ載せる前提とする。

## 5. プロジェクト構成（as-built）
```
clipy-si-macos/
├─ Clipy.xcodeproj                 # 新規（scheme: Clipy）
├─ Clipy/
│  ├─ App/                         # ClipyApp.swift, AppDelegate.swift
│  ├─ MenuBar/                     # StatusMenuController, FloatingPanel, NSHosting* 行
│  ├─ Capture/                     # PasteboardMonitor, ClipSnapshot, PrivacyMarkers
│  ├─ Persistence/                 # Schema(@Table), Migrations, ClipRepository, SnippetRepository
│  ├─ Input/                       # HotKeyService, PasteService, AccessibilityService, ExcludeApp
│  ├─ Snippets/                    # SwiftUI editor, AEXML import/export
│  ├─ Settings/                    # Settings scene + 各タブ View
│  ├─ Security/                    # Keychain 鍵管理, 暗号化 blob ストア
│  ├─ Update/                      # Sparkle 連携
│  └─ Resources/                   # Assets, Info.plist, *.entitlements, localization
├─ ClipyTests/
├─ Configurations/                 # *.xcconfig（署名は AdHoc トグル踏襲）
└─ .swiftlint.yml                  # repos/Clipy から移植
```
命名は `CPY*` 接頭辞を踏襲不要。ただし**永続化される識別子・データ形式・UserDefaults キー・XML 要素名は互換維持**。

## 6. ビルド設定
- `MACOSX_DEPLOYMENT_TARGET = 14.0`、`SWIFT_VERSION = 6.0`、`SWIFT_STRICT_CONCURRENCY = complete`。移行中は Swift 5 + `complete`（警告）→ leaf から上へ → 最後に app ターゲットを言語モード 6 に。`@preconcurrency import` で未対応依存のノイズ抑制。
- ユニバーサル: `ARCHS = $(ARCHS_STANDARD)`、Debug は `ONLY_ACTIVE_ARCH=YES` / Release は `NO`。`lipo -archs` で `x86_64 arm64` を確認。
- `ENABLE_HARDENED_RUNTIME = YES`（実装は Release 構成のみ。Debug はホストテストのため無効）。entitlements ファイルは**結果的に不要**（§11）。署名は xcconfig トグルではなく、pbxproj は ad-hoc のまま `Scripts/release-notarize.sh` が Developer ID を xcodebuild オーバーライドで注入する方式に確定（証明書なしのコントリビュータビルドを壊さない）。
- **製品名（PRODUCT_NAME / CFBundleName）は `ClipySi`**、**Bundle id は Release `io.github.ponponusa.clipysi` / Debug `io.github.ponponusa.clipysi.debug` / tests `…clipysi.tests`**（メンテナの個人 GitHub アカウント由来の逆 DNS。`<user>.github.io` → `io.github.<user>`）。上流 Clipy（MIT）の「派生物に `Clipy`/`ClipMenu` の製品名を使わない」要請を尊重して **`ClipySi` へ改名**（出力は `ClipySi.app`）。一方、Xcode の **scheme / target / `Clipy.xcodeproj` 名と Swift モジュール名（`PRODUCT_MODULE_NAME = Clipy`）は内部的に `Clipy` のまま固定**＝`-scheme Clipy` などのビルド系コマンドとテストの `import Clipy`（26 ファイル）を壊さないため。これにより製品版 Clipy v1.2.1（`/Applications/Clipy.app`、`com.clipy-app.Clipy`）とは完全に別アプリとなり、TCC/Accessibility 付与・環境設定・LaunchServices が衝突しない。Debug/Release も分離して開発ビルドが Release の状態を汚さないようにする。
  - 注: 将来このリライトを既存 Clipy ユーザーへ Sparkle で in-place アップグレード配信したい場合は、Release id を `com.clipy-app.Clipy` に戻す判断が必要（同一 id でないと「同じアプリの更新」と認識されない）。リリース時に再検討。
- 開発初期はローカル実行のため ad-hoc 署名（`CODE_SIGN_IDENTITY = "-"`, `CODE_SIGN_STYLE = Manual`, `DEVELOPMENT_TEAM = ""`）。Info.plist は `GENERATE_INFOPLIST_FILE=YES` + `INFOPLIST_KEY_*` で生成（Sparkle 等の固定キーが要る段階で実体 plist に移行）。pbxproj は Xcode 16+ の `PBXFileSystemSynchronizedRootGroup`（ファイル自動同期）で最小化。
- `SWIFT_UPCOMING_FEATURE_*`（ExistentialAny 等）を段階導入。CI では任意で `SWIFT_TREAT_WARNINGS_AS_ERRORS`。

## 7. 依存関係
- **維持**: Magnet, Sauce, KeyHolder, Screeen, Sparkle, LoginServiceKit→**SMAppService に置換**。
- **新規/採用**: SQLiteData(+GRDB, swift-structured-queries), swift-dependencies, swift-sharing, swift-tagged, AEXML（スニペット XML）, SwiftLintPlugins（ビルド内 lint）, CryptoKit（標準）。
- **廃止**: RealmSwift/realm-core, RxSwift/RxCocoa, PINCache/PINOperation, swift-perception（14+ で不要）, レガシー NSCoding 永続化, dsa_pub.pem。

## 8. データ移行（v1 → 新ストア）
リライトの最大の隠れ作業。**一度きりの idempotent インポータ**を実装（schema migration ではなくアプリ層コード + 完了フラグ）:
1. `bootstrapDatabase()` のマイグレーション成功後・UI 読込前に実行。
2. 既存 Realm（`CPYClip`/`CPYFolder`/`CPYSnippet`）+ PINCache サムネイル + `.data` アーカイブ + UserDefaults（除外アプリ/ホットキー）を 1 GRDB トランザクションで新テーブルへ。Realm の `enable`→`isEnabled`、`identifier`(String)→`Tagged UUID` のマッピングに注意。
3. リリース猶予後、Realm / RxSwift / PINCache / `.data` / DSA を削除。
4. 以後は `DatabaseMigrator` の v2, v3… でスキーマ進化。
- **識別子・UserDefaults キー・XML 要素名・スニペット並び順は厳密に保持**（paste アクションや設定の継続性のため）。

## 9. テスト戦略
- swift-dependencies で全 I/O（DB / pasteboard / 時計 / ファイル）を注入し、**システム権限（Accessibility / ホットキー / 実 pasteboard）無しで実行**できるよう設計。
- DB テストは in-memory（`.dependency(\.defaultDatabase, ...)`）、pasteboard はスタブ。**実 `NSPasteboard.general` やユーザー履歴 DB を絶対に触らない**。
- pointfree スタックは Swift Testing 主体。`xcodebuild test` は XCTest/Swift Testing 両対応。
- 重点: dedupe ハッシュの安定性、プライバシーマーカー判定、retention/GC、移行インポータ、メニュー番号付けのエッジケース（10 件時の wrap、start-from-zero）。

## 10. CI
オリジナルの形を踏襲（macos-26 / Xcode 26.5、SPM キャッシュ、`-skipPackagePluginValidation -skipMacroValidation`）:
```bash
set -o pipefail && xcodebuild \
  -project Clipy.xcodeproj -scheme Clipy \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -clonedSourcePackagesDirPath "$WS/.spm-cache/SourcePackages" \
  -packageCachePath "$WS/.spm-cache/PackageCache" \
  -skipPackagePluginValidation -skipMacroValidation \
  clean test | xcbeautify --renderer github-actions
```
lint は SwiftLintPlugins（ビルド内）+ PR 注釈用に `swiftlint lint --strict --reporter github-actions-logging`。CodeQL も維持。

## 11. 配布
- **App Sandbox は付けない**: 貼り付けが Accessibility + `CGEvent.post` に依存し sandbox 非対応。CGEvent 系クリップボードマネージャは MAS で 2.4.5 却下例あり → **Developer ID + notarization で MAS 外配布**。
- **Hardened Runtime 必須**（notarization 前提）。entitlements は最小限 — 実績（2026-06-12）: **entitlements ゼロで公証通過**。SPM の Sparkle はビルド時に同一チームで再署名されるため `com.apple.security.cs.disable-library-validation` も不要だった。CGEvent post 自体に専用 entitlement は不要（Accessibility TCC で制御）。
- TCC は **Accessibility のみ**要求（Input Monitoring は不要: ホットキーは Carbon `RegisterEventHotKey`=Magnet で権限不要、貼り付けは post であって tap ではない）。
- ユニバーサル化（全依存に arm64+x86_64 スライス）。
- notarize: `notarytool store-credentials` → inner-to-outer 署名（`--options runtime --timestamp`、`--deep` 回避）→ `ditto -c -k --keepParent` → `notarytool submit --wait` → `stapler staple`（zip は staple 不可、.app/.dmg を staple）。検証: `spctl -a -vvv -t exec`, `stapler validate`, `codesign --verify --deep --strict`。quarantine 付きでクリーンな macOS 14+ 機で実機確認。**実装済み**: `Scripts/release-notarize.sh` がこの全手順を自動化（Sparkle のネスト 4 バイナリ Downloader.xpc/Installer.xpc/Autoupdate/Updater.app の再署名込み）。v1.0.0 は notarize/staple/`spctl`/quarantine launch を確認済み。

## 12. 既知のリスク・未解決事項
- 新 pasteboard プライバシー（`accessBehavior` / `detectPatterns` / システムの読取アラート、macOS 26 系）は `#available` で分岐。`changeCount` 読取がアラート対象外かは beta 実機で要確認（`defaults write <bundle> EnablePasteboardPrivacyDeveloperPreview -bool yes`）。「always allow」を自プログラムで要求する API は無い → ユーザー誘導のみ。
- accessory アプリでの Settings オープン手順は OS バージョン依存・脆い（§4.6）。リリース毎に再確認。
- 署名 ID が変わると Accessibility の TCC 付与がリセットされ paste が一時的に壊れる（再承認が必要）。
- SMAppService は /Applications 配置 + 署名/notarize 前提で `.requiresApproval` になり得る。UI は `.status` を反映すること。
- MenuBarExtra 系・新 pasteboard API・SQLiteData 1.6.x のメソッド名はバージョン依存。実装時にコンパイル確認。
