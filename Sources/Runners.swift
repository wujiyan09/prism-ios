import Foundation
import SQLite3
import JavaScriptCore
import WebKit

// MARK: - SQLite

struct ResultSet: Identifiable {
    let id = UUID()
    var columns: [String]
    var rows: [[String]]
}


final class SQLDatabase {
    private var db: OpaquePointer?

    init() { sqlite3_open(":memory:", &db) }
    deinit { sqlite3_close(db) }

    static func norm(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_NULL: return "NULL"
        case SQLITE_INTEGER: return String(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT:
            let v = sqlite3_column_double(stmt, i)
            let r = (v * 1e6).rounded() / 1e6
            if r == r.rounded(), abs(r) < 1e15 { return String(Int64(r)) }
            return String(r)
        default:
            if let c = sqlite3_column_text(stmt, i) { return String(cString: c) }
            return ""
        }
    }

    /// Runs every statement; returns the result sets that produced rows (like sql.js `exec`).
    @discardableResult
    func exec(_ sql: String) throws -> [ResultSet] {
        var out: [ResultSet] = []
        var remaining = sql
        while true {
            let trimmed = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { break }
            var stmt: OpaquePointer?
            var tailOffset = 0
            let rc: Int32 = trimmed.withCString { base in
                var tail: UnsafePointer<CChar>?
                let r = sqlite3_prepare_v2(db, base, -1, &stmt, &tail)
                if let tail { tailOffset = tail - base }
                return r
            }
            if rc != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                sqlite3_finalize(stmt)
                throw NSError(domain: "SQL", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
            }
            let utf8 = Array(trimmed.utf8)
            remaining = String(decoding: utf8[min(tailOffset, utf8.count)...], as: UTF8.self)
            guard let stmt else { continue }
            let n = sqlite3_column_count(stmt)
            var rs = ResultSet(columns: (0..<n).map { String(cString: sqlite3_column_name(stmt, $0)) }, rows: [])
            while true {
                let s = sqlite3_step(stmt)
                if s == SQLITE_ROW {
                    rs.rows.append((0..<n).map { Self.norm(stmt, $0) })
                } else if s == SQLITE_DONE {
                    break
                } else {
                    let msg = String(cString: sqlite3_errmsg(db))
                    sqlite3_finalize(stmt)
                    throw NSError(domain: "SQL", code: Int(s), userInfo: [NSLocalizedDescriptionKey: msg])
                }
            }
            sqlite3_finalize(stmt)
            if n > 0 && !rs.rows.isEmpty { out.append(rs) }
        }
        return out
    }
}

// MARK: - Check results

struct CheckLine: Identifiable, Hashable {
    let id = UUID()
    var ok: Bool
    var text: String
}

struct RunOutcome {
    var pass = false
    var tables: [ResultSet] = []
    var expected: [ResultSet]? = nil
    var stdout = ""
    var error = ""
    var lines: [CheckLine] = []
    var expectedOutput: String? = nil
}

enum Runner {
    static func run(_ p: Practical, code: String) async -> RunOutcome {
        let lang = (p.lang ?? "").lowercased()
        let type = p.check?.type ?? ""
        if lang == "sql" { return runSQL(p, code: code) }
        if lang == "js" && type == "js_tests" { return runJS(p, code: code) }
        if lang == "python" { return await WebRunner.shared.python(p, code: code) }
        if lang == "html" || type == "html_dom" { return await WebRunner.shared.dom(p, code: code) }
        var o = RunOutcome(); o.error = "This exercise is checked against the model answer."
        return o
    }

    /// Free-form run for "Try it" boxes.
    static func free(lang: String, code: String, stdin: String) async -> (out: String, err: String) {
        switch lang.lowercased() {
        case "python", "py":
            let chk = Check(type: "py_stdout", tests: nil, stdin: stdin, expect: nil, checks: nil, model: nil, expected_sql: nil)
            let p = Practical(t: "", tz: nil, lang: "python", sec: nil, task: "", taskz: nil, setup: nil, starter: nil, check: chk, solution: nil, src: nil)
            let o = await WebRunner.shared.python(p, code: code)
            return (o.stdout, o.error)
        case "js", "javascript":
            let ctx = JSContext()!
            var logs: [String] = []
            let log: @convention(block) (JSValue) -> Void = { v in logs.append(v.toString()) }
            let console = JSValue(newObjectIn: ctx)!
            console.setObject(log, forKeyedSubscript: "log" as NSString)
            ctx.setObject(console, forKeyedSubscript: "console" as NSString)
            var err = ""
            ctx.exceptionHandler = { _, e in err = e?.toString() ?? "Error" }
            ctx.evaluateScript(code)
            return (logs.joined(separator: "\n"), err)
        default:
            return ("", "This language can't run on the device.")
        }
    }

    static func runSQL(_ p: Practical, code: String) -> RunOutcome {
        var o = RunOutcome()
        func fresh() throws -> SQLDatabase {
            let db = SQLDatabase()
            if let s = p.setup, !s.isEmpty { try db.exec(s) }
            return db
        }
        do {
            o.tables = try fresh().exec(code)
        } catch {
            o.error = error.localizedDescription
            if let exp = p.check?.expected_sql { o.expected = try? fresh().exec(exp) }
            return o
        }
        guard p.check?.type == "sql_result", let expSQL = p.check?.expected_sql else { o.pass = o.error.isEmpty; return o }
        let e = (try? fresh().exec(expSQL)) ?? []
        func rows(_ r: [ResultSet]) -> [String] { r.last.map { $0.rows.map { $0.joined(separator: "|") } } ?? [] }
        var A = rows(o.tables), B = rows(e)
        if expSQL.range(of: #"order\s+by"#, options: [.regularExpression, .caseInsensitive]) == nil { A.sort(); B.sort() }
        o.pass = A == B
        if !o.pass { o.expected = e }
        return o
    }

    static func runJS(_ p: Practical, code: String) -> RunOutcome {
        var o = RunOutcome(); o.pass = true
        for t in p.check?.tests ?? [] {
            let ctx = JSContext()!
            var logs: [String] = []
            let log: @convention(block) (JSValue) -> Void = { v in logs.append(v.toString()) }
            let console = JSValue(newObjectIn: ctx)!
            console.setObject(log, forKeyedSubscript: "log" as NSString)
            ctx.setObject(console, forKeyedSubscript: "console" as NSString)
            ctx.setObject(code, forKeyedSubscript: "__code" as NSString)
            ctx.setObject(t.call, forKeyedSubscript: "__call" as NSString)
            let script = """
            (function(){ try { var r = (new Function(__code + "\\n;return (" + __call + ");"))();
              return [String(r), typeof r === "string" ? r : JSON.stringify(r)]; }
              catch(e) { return ["Error: " + e.message, ""]; } })()
            """
            let res = ctx.evaluateScript(script)?.toArray() as? [String] ?? ["Error", ""]
            let ok = res[0] == t.expect.value || res[1] == t.expect.value
            if !ok { o.pass = false }
            o.lines.append(CheckLine(ok: ok, text: "\(t.call) → \(res[0])" + (ok ? "" : "  (expected \(t.expect.value))")))
            if !logs.isEmpty && o.stdout.isEmpty { o.stdout = logs.joined(separator: "\n") }
        }
        return o
    }
}

// MARK: - Headless web engine for Python (Pyodide) and HTML DOM checks.
// It is never shown on screen; all UI stays native.

@MainActor
final class WebRunner: NSObject, WKNavigationDelegate {
    static let shared = WebRunner()
    private var web: WKWebView?
    private var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func engine() async -> WKWebView {
        if let web, ready { return web }
        if web == nil {
            let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 400), configuration: WKWebViewConfiguration())
            w.navigationDelegate = self
            web = w
            w.loadHTMLString("<!doctype html><html><head><meta charset='utf-8'></head><body></body></html>",
                             baseURL: URL(string: "https://ict.app.local/"))
        }
        await withCheckedContinuation { c in
            if ready { c.resume() } else { waiters.append(c) }
        }
        return web!
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.ready = true
            let w = self.waiters; self.waiters = []
            w.forEach { $0.resume() }
        }
    }

    private struct PyResult: Decodable {
        struct T: Decodable { let call: String; let got: String; let ok: Bool; let expect: String }
        let out: String; let err: String; let pass: Bool; let tests: [T]?; let loadError: String?
    }

    func python(_ p: Practical, code: String) async -> RunOutcome {
        var o = RunOutcome()
        let w = await engine()
        let c = p.check
        let tests = (c?.tests ?? []).map { ["call": $0.call, "expect": $0.expect.value] }
        let js = """
        try {
          if (!window.__py) {
            if (!window.loadPyodide) {
              await new Promise((ok, no) => { const s = document.createElement('script');
                s.src = 'https://cdn.jsdelivr.net/pyodide/v0.26.4/full/pyodide.js';
                s.onload = ok; s.onerror = () => no(new Error('Python engine could not be downloaded')); document.head.appendChild(s); });
            }
            window.__py = await loadPyodide();
          }
        } catch (e) { return JSON.stringify({out:'', err:'', pass:false, loadError: String(e.message || e)}); }
        const py = window.__py;
        py.globals.set('__user', code); py.globals.set('__setup', setup); py.globals.set('__stdin', stdin);
        const res = py.runPython(`
        import sys,io,traceback
        __o=io.StringIO();__g={}
        sys.stdout=__o;sys.stdin=io.StringIO(__stdin)
        __err=""
        try:
            exec(__setup,__g);exec(__user,__g)
        except Exception:
            __err=traceback.format_exc(limit=1)
        sys.stdout=sys.__stdout__
        [__o.getvalue(),__err]`).toJs();
        const so = res[0], err = res[1];
        let pass = false; const out = [];
        if (ctype === 'py_stdout') {
          const n = s => String(s).trim().replace(/\\s+\\n/g, '\\n');
          pass = !err && n(so) === n(expect);
        } else if (ctype === 'py_tests') {
          pass = !err;
          for (const t of tests) {
            py.globals.set('__call', t.call);
            let got;
            try { got = py.runPython(`
        try:
            __r=eval(__call,__g);__s=[str(__r),repr(__r)]
        except Exception as e:
            __s=["Error: "+repr(e),""]
        __s`).toJs(); } catch (e) { got = [String(e), '']; }
            const ok = got[0] === String(t.expect) || got[1] === String(t.expect);
            if (!ok) pass = false;
            out.push({call: t.call, got: got[0], ok, expect: String(t.expect)});
          }
        } else { pass = !err; }
        return JSON.stringify({out: so, err, pass, tests: out});
        """
        do {
            let r = try await w.callAsyncJavaScript(js, arguments: [
                "code": code, "setup": p.setup ?? "", "stdin": c?.stdin ?? "", "ctype": c?.type ?? "",
                "expect": c?.expect ?? "", "tests": tests,
            ], in: nil, contentWorld: .page)
            guard let s = r as? String, let d = s.data(using: .utf8), let pr = try? JSONDecoder().decode(PyResult.self, from: d) else {
                o.error = "No result"; return o
            }
            if let le = pr.loadError { o.error = le + "\n(Python needs an internet connection the first time.)"; return o }
            o.stdout = pr.out; o.error = pr.err; o.pass = pr.pass
            if c?.type == "py_stdout" && !pr.pass { o.expectedOutput = c?.expect }
            o.lines = (pr.tests ?? []).map { CheckLine(ok: $0.ok, text: "\($0.call) → \($0.got)" + ($0.ok ? "" : "  (expected \($0.expect))")) }
        } catch {
            o.error = error.localizedDescription
        }
        return o
    }

    private struct DomResult: Decodable { struct L: Decodable { let ok: Bool; let msg: String }; let pass: Bool; let lines: [L] }

    func dom(_ p: Practical, code: String) async -> RunOutcome {
        var o = RunOutcome()
        let w = await engine()
        let checks: [[String: Any]] = (p.check?.checks ?? []).map { k in
            var d: [String: Any] = ["sel": k.sel]
            if let c = k.count { d["count"] = c }
            if let t = k.text { d["text"] = t }
            if let a = k.attr { d["attr"] = a }
            if let v = k.value { d["value"] = v.value }
            if let s = k.style { d["style"] = s }
            return d
        }
        let js = """
        return await new Promise(res => {
          const f = document.createElement('iframe'); f.style.display = 'none';
          f.setAttribute('sandbox', 'allow-same-origin'); document.body.appendChild(f);
          f.onload = () => { const d = f.contentDocument; let pass = true; const lines = [];
            for (const k of checks) {
              let els = []; try { els = [...d.querySelectorAll(k.sel)]; } catch (e) {}
              let ok = true, msg = k.sel;
              if (k.count != null) { ok = els.length === k.count; msg += ` × ${els.length} (need ${k.count})`; }
              else if (!els.length) { ok = false; msg += ' not found'; }
              if (ok && k.text != null) { ok = els.some(e => e.textContent.trim().includes(k.text)); msg += ` "${k.text}"`; }
              if (ok && k.attr) { ok = els.some(e => k.value == null ? e.hasAttribute(k.attr) : e.getAttribute(k.attr) == k.value); msg += ` [${k.attr}${k.value != null ? '=' + k.value : ''}]`; }
              if (ok && k.style) { ok = els.some(e => f.contentWindow.getComputedStyle(e)[k.style] === k.value); msg += ` {${k.style}: ${k.value}}`; }
              if (!ok) pass = false; lines.push({ok, msg});
            }
            f.remove(); res(JSON.stringify({pass, lines}));
          };
          f.srcdoc = code;
        });
        """
        do {
            let r = try await w.callAsyncJavaScript(js, arguments: ["code": code, "checks": checks], in: nil, contentWorld: .page)
            if let s = r as? String, let d = s.data(using: .utf8), let dr = try? JSONDecoder().decode(DomResult.self, from: d) {
                o.pass = dr.pass
                o.lines = dr.lines.map { CheckLine(ok: $0.ok, text: $0.msg) }
            }
        } catch {
            o.error = error.localizedDescription
        }
        return o
    }
}
