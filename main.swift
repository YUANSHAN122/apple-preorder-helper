import Cocoa
import WebKit
import JavaScriptCore

let colors = ["夜空色", "星光白色"]
let sizes = ["256GB", "512GB", "1TB", "2TB"]
let codes = [["mk2n4ch", "mk2q4ch", "mk2u4ch", "mk2w4ch"], ["mk2m4ch", "mk2p4ch", "mk2t4ch", "mk2v4ch"]]
func productURL(_ color: Int, _ size: Int) -> URL {
    URL(string: "https://www.apple.com.cn/shop/buy-iphone/iphone-duo/\(codes[color][size])/a")!
}
func dateFormatter() -> DateFormatter {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
}
// Run only on the selected product page. Never click checkout/payment controls.
func probeScript(color: String, size: String, auto: Bool) -> String {
    let values = try! JSONSerialization.data(withJSONObject: [color, size])
    let args = String(data: values, encoding: .utf8)!
    return """
    (() => {
      const [color,size] = \(args);
      if (location.hostname !== 'www.apple.com.cn') return 'handoff';
      if (!location.pathname.includes('/shop/buy-iphone/iphone-duo')) return 'handoff';
      const body = document.body?.innerText || '';
      if (/验证码|验证您是真人|验证你是真人|verify you are human/i.test(body)) return 'verify';
      const buttons = [...document.querySelectorAll('button')].filter(b =>
        b.getClientRects().length && /^(加入购物袋|添加到购物袋|Add to Bag)$/i.test(b.innerText.trim()) &&
        !b.disabled && b.getAttribute('aria-disabled') !== 'true');
      if (buttons.length !== 1) {
        if (/选择你的|选择您的|选择外观|选择容量/.test(body)) return 'configure';
        return 'waiting';
      }
      // A matching title is required so a generic landing page cannot add another variant.
      if (!document.title.includes('iPhone Duo') || !document.title.includes(color) ||
          !document.title.replace(/\\s/g,'').includes(size)) return 'mismatch';
      if (!\(auto ? "true" : "false")) return 'ready';
      buttons[0].click(); return 'clicked';
    })()
    """
}

final class App: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    var window: NSWindow!
    let web = WKWebView(frame: .zero)
    let color = NSPopUpButton(), size = NSPopUpButton()
    let time = NSTextField(string: "2026-10-16 20:00:00")
    let status = NSTextField(wrappingLabelWithString: "选择规格后点击开始。")
    let countdown = NSTextField(labelWithString: "准备就绪")
    let automatic = NSButton(checkboxWithTitle: "尝试自动加入购物袋", target: nil, action: nil)
    var startButton: NSButton!, stopButton: NSButton!, timer: Timer?
    var active = false, loading = false, probing = false, generation = 0
    var target = Date(), lastReload = Date.distantPast, lastProbe = Date.distantPast
    var colorIndex = 0, sizeIndex = 0, auto = false, failures = 0
    var activity: NSObjectProtocol?
    func label(_ text: String, _ font: NSFont = .systemFont(ofSize: 13)) -> NSTextField {
        let x = NSTextField(wrappingLabelWithString: text); x.font = font; return x
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu(), item = NSMenuItem(); menu.addItem(item)
        let sub = NSMenu(); sub.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = sub; NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1240,height: 800), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "苹果预购助手 · 中国大陆"; window.minSize = NSSize(width: 1000,height: 680)
        let root = NSView(); window.contentView = root
        let panel = NSStackView(); panel.orientation = .vertical; panel.alignment = .leading; panel.spacing = 14
        panel.translatesAutoresizingMaskIntoConstraints = false; web.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(panel); root.addSubview(web)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: root.leadingAnchor,constant: 22), panel.topAnchor.constraint(equalTo: root.topAnchor,constant: 24), panel.widthAnchor.constraint(equalToConstant: 270),
            web.leadingAnchor.constraint(equalTo: panel.trailingAnchor,constant: 20),web.trailingAnchor.constraint(equalTo: root.trailingAnchor),web.topAnchor.constraint(equalTo: root.topAnchor),web.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        color.addItems(withTitles: colors); size.addItems(withTitles: sizes)
        panel.addArrangedSubview(label("iPhone Duo", .boldSystemFont(ofSize: 27)))
        panel.addArrangedSubview(label("地区：中国大陆\n北京时间 10 月 16 日 20:00 开始"))
        panel.addArrangedSubview(label("颜色")); panel.addArrangedSubview(color)
        panel.addArrangedSubview(label("容量")); panel.addArrangedSubview(size)
        panel.addArrangedSubview(label("开售时间（北京时间）"));panel.addArrangedSubview(time)
        time.widthAnchor.constraint(equalToConstant: 260).isActive = true
        panel.addArrangedSubview(automatic)
        panel.addArrangedSubview(label("付款需在苹果官网手动完成。"))
        startButton = NSButton(title: "开始倒计时",target: self,action: #selector(start))
        stopButton = NSButton(title: "暂停 / 接手操作",target: self,action: #selector(stop)); stopButton.isEnabled = false
        panel.addArrangedSubview(startButton);panel.addArrangedSubview(stopButton)
        panel.addArrangedSubview(NSButton(title: "用默认浏览器打开所选规格",target: self,action: #selector(openBrowser)))
        countdown.font = .monospacedDigitSystemFont(ofSize: 21,weight: .semibold)
        panel.addArrangedSubview(countdown);panel.addArrangedSubview(status)
        status.widthAnchor.constraint(equalToConstant: 260).isActive = true
        panel.addArrangedSubview(label("开售后每 8 秒最多刷新一次，最长 10 分钟。验证码、登录、规格选择需要你接手。电脑必须联网、保持开盖；关闭程序就会停止。"))
        web.navigationDelegate = self;web.uiDelegate = self
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps: true)
        // Do not visit the store until the user starts or explicitly opens it.
        web.loadHTMLString("<meta charset='utf-8'><body style='font:20px -apple-system;padding:60px;color:#555'>选择颜色与容量，然后开始倒计时。<br><br>官网将在右侧打开。</body>",baseURL: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5,repeats: true) { [weak self] _ in self?.tick() }
    }
    @objc func openBrowser() { NSWorkspace.shared.open(productURL(color.indexOfSelectedItem,size.indexOfSelectedItem)) }
    @objc func start() {
        guard let date = dateFormatter().date(from: time.stringValue) else { status.stringValue = "时间格式：2026-10-16 20:00:00";return }
        guard Date().timeIntervalSince(date) < 600 else { status.stringValue = "设定时间已过去超过 10 分钟，请修改后再开始。";return }
        generation += 1; target = date;active = true;auto = automatic.state == .on
        colorIndex = color.indexOfSelectedItem;sizeIndex = size.indexOfSelectedItem; failures = 0
        [color,size,time,automatic,startButton].forEach { $0.isEnabled = false };stopButton.isEnabled = true
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled,.idleDisplaySleepDisabled],reason: "Apple preorder countdown")
        reload();status.stringValue = "倒计时运行中：\(colors[colorIndex]) / \(sizes[sizeIndex])。"
    }
    func halt(_ message: String, alert: Bool = false) {
        active = false;generation += 1;probing = false
        [color,size,time,automatic,startButton].forEach { $0.isEnabled = true };stopButton.isEnabled = false
        if let a = activity { ProcessInfo.processInfo.endActivity(a);activity = nil }
        status.stringValue = message
        if alert { NSSound.beep();NSApp.requestUserAttention(.criticalRequest) }
    }
    @objc func stop() { halt("已暂停自动操作，可以手动操作右侧官网。") }
    func reload() {
        lastReload = Date();loading = true
        web.load(URLRequest(url: productURL(colorIndex,sizeIndex),cachePolicy: .reloadIgnoringLocalCacheData,timeoutInterval: 20))
    }
    func tick() {
        guard active else { return }
        let now = Date(), left = target.timeIntervalSince(now)
        if left > 0 {
            let t = Int(ceil(left));countdown.stringValue = String(format:"%02d:%02d:%02d",t/3600,(t/60)%60,t%60)
            return
        }
        countdown.stringValue = "开售时间已到"
        if now.timeIntervalSince(target) > 600 { halt("已达到 10 分钟上限，请手动检查官网。",alert: true);return }
        // Probe the currently loaded page before any refresh so an enabled bag button is not missed.
        guard !loading && !probing else { return }
        if now.timeIntervalSince(lastProbe) < 1 { return }
        probing = true;lastProbe = now;let token = generation
        web.evaluateJavaScript(probeScript(color: colors[colorIndex],size: sizes[sizeIndex],auto: auto)) { [weak self] result,error in
            guard let self = self, self.generation == token, self.active else { return }
            self.probing = false
            if error != nil { self.halt("无法读取官网页面，请手动操作。",alert: true);return }
            switch result as? String {
            case "clicked": self.halt("已点击加入购物袋，请确认官网结果并手动结账。",alert: true)
            case "ready": self.halt("官网已出现加入购物袋按钮，请手动购买。",alert: true)
            case "handoff": self.halt("已进入其他页面，自动操作暂停，请手动继续。",alert: true)
            case "verify": self.halt("官网要求验证，请手动完成。",alert: true)
            case "configure": self.halt("官网需要选择配置，请手动继续。",alert: true)
            case "mismatch": self.halt("页面规格与所选规格无法核对，请手动检查。",alert: true)
            default:
                self.status.stringValue = "暂未发现可用的加入购物袋按钮，等待刷新。"
                if Date().timeIntervalSince(self.lastReload) >= 8 { self.reload() }
            }
        }
    }
    func webView(_ webView: WKWebView,didFinish navigation: WKNavigation!) { loading = false;failures = 0 }
    func failed(_ error: Error) {
        loading = false;failures += 1
        if failures >= 3 { halt("连续加载失败，请检查网络后重新开始。",alert: true) }
        else { status.stringValue = "官网加载失败：\(error.localizedDescription)" }
    }
    func webView(_ webView: WKWebView,didFailProvisionalNavigation navigation: WKNavigation!,withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView,didFail navigation: WKNavigation!,withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView,decidePolicyFor action: WKNavigationAction,decisionHandler: @escaping (WKNavigationActionPolicy)->Void) {
        if action.navigationType == .linkActivated && active { halt("已切换为手动选购。") }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView,createWebViewWith configuration: WKWebViewConfiguration,for action: WKNavigationAction,windowFeatures: WKWindowFeatures)->WKWebView? {
        if let url = action.request.url { halt("新页面已在默认浏览器打开，请手动继续。");NSWorkspace.shared.open(url) };return nil
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication)->Bool { true }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate();if let a = activity { ProcessInfo.processInfo.endActivity(a) } }
}

func selfTest() {
    assert(Set(codes.flatMap{$0}).count == 8)
    assert(productURL(0,0).host == "www.apple.com.cn")
    let d = dateFormatter().date(from: "2026-10-16 20:00:00")!
    assert(Int(d.timeIntervalSince1970) == 1792152000)
    func check(_ expected: String,_ setup: String,_ auto: Bool = false) {
        let c = JSContext()!
        c.evaluateScript("""
        var clicks=0;
        var location={hostname:'www.apple.com.cn',pathname:'/shop/buy-iphone/iphone-duo/mk2n4ch/a'};
        var button={innerText:'加入购物袋',disabled:false,getClientRects:()=>[1],getAttribute:()=>null,click:()=>{clicks++}};
        var document={title:'购买 iPhone Duo 256GB 夜空色',body:{innerText:''},querySelectorAll:()=>[button]};
        \(setup)
        """)
        let got=c.evaluateScript(probeScript(color:"夜空色",size:"256GB",auto:auto))?.toString()
        assert(got == expected,"expected \(expected), got \(String(describing:got))")
        assert(c.evaluateScript("clicks")!.toInt32() == (expected == "clicked" ? 1 : 0))
    }
    check("ready", "")
    check("clicked", "",true)
    check("waiting", "button.disabled=true;",true)
    check("waiting", "button.getClientRects=()=>[];",true)
    check("waiting", "button.innerText='立即付款';",true)
    check("mismatch", "document.title='购买 iPhone Duo 512GB 夜空色';",true)
    check("handoff", "location.hostname='secure.store.apple.com.cn';",true)
    check("verify", "document.body.innerText='请输入验证码';",true)
    check("configure", "document.body.innerText='选择容量';document.querySelectorAll=()=>[];",true)
    check("waiting", "document.querySelectorAll=()=>[button,button];",true)
    print("PASS: 8 variant URLs, Beijing time, 10 page-detection/click-guard cases")
}
if CommandLine.arguments.contains("--self-test") { selfTest() }
else { let app=NSApplication.shared;let delegate=App();app.delegate=delegate;app.run() }
