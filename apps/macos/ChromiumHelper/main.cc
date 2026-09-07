#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_v8.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"
#include <map>

namespace {
class DevToolsFunction final : public CefV8Handler {
 public:
  bool Execute(const CefString& name, CefRefPtr<CefV8Value>, const CefV8ValueList& arguments,
               CefRefPtr<CefV8Value>&, CefString&) override {
    if (arguments.size() != 1 || !arguments[0]->IsString()) return false;
    auto message = CefProcessMessage::Create("CodevisorDevTools." + name.ToString());
    message->GetArgumentList()->SetString(0, arguments[0]->GetStringValue());
    CefV8Context::GetCurrentContext()->GetFrame()->SendProcessMessage(PID_BROWSER, message);
    return true;
  }
 private:
  IMPLEMENT_REFCOUNTING(DevToolsFunction);
};

class Application final : public CefApp, public CefRenderProcessHandler {
 public:
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }
  void OnBrowserCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDictionaryValue> extra) override {
    if (extra && extra->GetBool("codevisorDevTools")) frontends_[browser->GetIdentifier()] = extra->GetString("dockSide");
  }
  void OnBrowserDestroyed(CefRefPtr<CefBrowser> browser) override { frontends_.erase(browser->GetIdentifier()); }
  void OnContextCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override {
    if (!IsFrontend(browser, frame)) return;
    auto bridge = CefV8Value::CreateObject(nullptr, nullptr);
    for (const auto* name : {"send", "close", "copy", "open", "dock", "focus", "ready"}) {
      bridge->SetValue(name, CefV8Value::CreateFunction(name, new DevToolsFunction()), V8_PROPERTY_ATTRIBUTE_READONLY);
    }
    bridge->SetValue("initialDockSide", CefV8Value::CreateString(frontends_.at(browser->GetIdentifier())), V8_PROPERTY_ATTRIBUTE_READONLY);
    context->GetGlobal()->SetValue("__codevisorDevTools", bridge, V8_PROPERTY_ATTRIBUTE_READONLY);
  }
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                 CefProcessId source, CefRefPtr<CefProcessMessage> message) override {
    if (source != PID_BROWSER || !IsFrontend(browser, frame)) return false;
    auto name = message->GetName();
    if (name != "CodevisorDevTools.message" && name != "CodevisorDevTools.docked" && name != "CodevisorDevTools.inspect") return false;
    auto context = frame->GetV8Context();
    if (!context || !context->Enter()) return true;
    const bool protocolMessage = name == "CodevisorDevTools.message";
    auto api = context->GetGlobal()->GetValue(protocolMessage ? "InspectorFrontendAPI" : "__codevisorDevTools");
    if (api && api->IsObject()) {
      auto dispatch = api->GetValue(protocolMessage ? "dispatchMessage" : name == "CodevisorDevTools.docked" ? "didDock" : "inspect");
      if (dispatch && dispatch->IsFunction()) {
        CefRefPtr<CefV8Value> argument = protocolMessage
            ? CefV8Value::CreateString(message->GetArgumentList()->GetString(0))
            : CefV8Value::CreateInt(message->GetArgumentList()->GetInt(0));
        dispatch->ExecuteFunction(api, {argument});
      }
    }
    context->Exit();
    return true;
  }
 private:
  bool IsFrontend(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame) const {
    return frontends_.contains(browser->GetIdentifier()) && frame->IsMain() &&
        frame->GetURL().ToString().starts_with("https://devtools.codevisor.invalid/");
  }
  std::map<int, CefString> frontends_;
  IMPLEMENT_REFCOUNTING(Application);
};
}

int main(int argc, char* argv[]) {
  CefScopedSandboxContext sandbox;
  if (!sandbox.Initialize(argc, argv)) return 1;
  CefScopedLibraryLoader library;
  if (!library.LoadInHelper()) return 1;
  return CefExecuteProcess(CefMainArgs(argc, argv), new Application(), nullptr);
}
