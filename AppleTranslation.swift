import AppKit
import SwiftUI
import Translation
import NaturalLanguage

public typealias SynorTranslationCallback = @convention(c) (UnsafePointer<CChar>) -> Void

// The callback's UTF-8 pointer is valid only during the call. All callbacks run on main.
@_cdecl("synor_apple_translate_start")
public func synorAppleTranslateStart(_ json: UnsafePointer<CChar>?, _ callback: SynorTranslationCallback?) {
    guard let json, let callback else { return }
    let payload = String(cString: json)
    Task { @MainActor in AppleTranslator.shared.start(payload, callback: callback) }
}

@_cdecl("synor_apple_translate_cancel")
public func synorAppleTranslateCancel(_ id: UnsafePointer<CChar>?) {
    guard let id else { return }
    let requestID = String(cString: id)
    Task { @MainActor in AppleTranslator.shared.cancel(requestID) }
}

private func emit(_ event: [String: Any], _ callback: SynorTranslationCallback) {
    guard let data = try? JSONSerialization.data(withJSONObject: event), let json = String(data: data, encoding: .utf8) else { return }
    json.withCString { callback($0) }
}

@MainActor
private final class TranslationJob {
    let id: String
    let text: String
    let callback: SynorTranslationCallback
    var task: Task<Void, Never>?
    var session: TranslationSession?
    var window: NSWindow?
    init(id: String, text: String, callback: @escaping SynorTranslationCallback) {
        self.id = id; self.text = text; self.callback = callback
    }
}

@MainActor
private final class AppleTranslator: NSObject, NSWindowDelegate {
    static let shared = AppleTranslator()
    private var current: TranslationJob?

    private func languageCode(_ input: String) -> String {
        let aliases = ["中文": "zh-Hans", "简体中文": "zh-Hans", "chinese": "zh-Hans", "zh": "zh-Hans",
                       "英语": "en", "英文": "en", "english": "en", "日语": "ja", "日本語": "ja", "japanese": "ja",
                       "繁體中文": "zh-Hant", "한국어": "ko", "français": "fr", "deutsch": "de",
                       "韩语": "ko", "korean": "ko", "法语": "fr", "french": "fr", "德语": "de", "german": "de",
                       "西班牙语": "es", "spanish": "es"]
        return aliases[input.lowercased()] ?? input
    }

    func start(_ payload: String, callback: @escaping SynorTranslationCallback) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let id = object["id"] as? String else {
            emit(["id": "", "error": "无效的 Apple 翻译请求。", "done": true], callback); return
        }
        guard let text = object["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            emit(["id": id, "error": "没有可翻译的文字。", "done": true], callback); return
        }
        guard text.utf16.count <= 16_000 else {
            emit(["id": id, "error": "单次翻译最多支持 16000 个字符，请分段翻译。", "done": true], callback); return
        }
        if let old = current { cancel(old.id) }
        let job = TranslationJob(id: id, text: text, callback: callback)
        current = job
        var sourceCode = object["sourceLanguage"] as? String ?? "auto"
        if sourceCode == "auto" || sourceCode.isEmpty {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            guard let detected = recognizer.dominantLanguage else {
                finish(job, error: "无法识别原文语言，请增加一些文字后重试。"); return
            }
            sourceCode = detected == .simplifiedChinese || detected == .traditionalChinese
                ? "zh-Hans" : detected.rawValue
        }
        let source = Locale.Language(identifier: languageCode(sourceCode))
        let target = Locale.Language(identifier: languageCode(object["targetLanguage"] as? String ?? object["target"] as? String ?? "en"))
        if source == target { finish(job, text: text); return }
        job.task = Task { @MainActor [weak self] in
            guard let self else { return }
            let availability: LanguageAvailability
            if #available(macOS 26.4, *) { availability = LanguageAvailability(preferredStrategy: .lowLatency) }
            else { availability = LanguageAvailability() }
            let status = await availability.status(from: source, to: target)
            guard self.current === job, !Task.isCancelled else { return }
            if status == .unsupported {
                self.finish(job, error: "Apple 翻译暂不支持这一语言组合。"); return
            }
            if status == .installed {
                let session: TranslationSession
                if #available(macOS 26.4, *) {
                    session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
                } else { session = TranslationSession(installedSource: source, target: target) }
                await self.translate(job, using: session)
            } else {
                self.showPreparation(job, source: source, target: target)
            }
        }
    }

    private func showPreparation(_ job: TranslationJob, source: Locale.Language, target: Locale.Language) {
        let configuration: TranslationSession.Configuration
        if #available(macOS 26.4, *) {
            configuration = .init(source: source, target: target, preferredStrategy: .lowLatency)
        } else { configuration = .init(source: source, target: target) }
        let view = TranslationPreparation(configuration: configuration, run: { [weak self] session in
            await self?.translate(job, using: session)
        }, cancel: { [weak self] in self?.cancel(job.id) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 210), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Synor · Apple 本地翻译"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: view)
        job.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    fileprivate func translate(_ job: TranslationJob, using session: TranslationSession) async {
        guard current === job else { return }
        job.session = session
        do {
            // A SwiftUI-managed session presents Apple's actual language download consent.
            try await session.prepareTranslation()
            guard current === job, !Task.isCancelled else { return }
            let result = try await session.translate(job.text)
            guard current === job, !Task.isCancelled else { return }
            finish(job, text: result.targetText)
        } catch {
            guard current === job else { return }
            finish(job, error: "Apple 本地翻译失败：\(error.localizedDescription)")
        }
    }

    private func finish(_ job: TranslationJob, text: String? = nil, error: String? = nil) {
        guard current === job else { return }
        current = nil
        job.window?.delegate = nil
        job.window?.close()
        job.window = nil
        job.session = nil
        job.task = nil
        if let text { emit(["id": job.id, "text": text], job.callback) }
        var event: [String: Any] = ["id": job.id, "done": true]
        if let error { event["error"] = error }
        emit(event, job.callback)
    }

    func cancel(_ id: String) {
        guard let job = current, job.id == id else { return }
        job.task?.cancel()
        job.session?.cancel()
        finish(job)
    }

    func windowWillClose(_ notification: Notification) {
        guard let job = current, let window = notification.object as? NSWindow, window === job.window else { return }
        cancel(job.id)
    }
}

private struct TranslationPreparation: View {
    let configuration: TranslationSession.Configuration
    let run: @MainActor (TranslationSession) async -> Void
    let cancel: @MainActor () -> Void
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("正在准备 Apple 本地翻译").font(.headline)
            Text("首次使用可能需要下载语言包，请确认系统提示。下载完成后在本机翻译。").multilineTextAlignment(.center)
            Button("取消", action: cancel)
        }
        .padding(24)
        .frame(width: 430, height: 210)
        .translationTask(configuration) { session in await run(session) }
    }
}
