#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod server;

use tauri::Manager;

fn route_from_args(args: &[String]) -> Option<String> {
    args.windows(2)
        .find_map(|pair| (pair[0] == "--route").then(|| pair[1].clone()))
        .filter(|route| route.starts_with('/') && !route.starts_with("//"))
}

fn main() {
    tauri::Builder::default()
        // Must be the first registered plugin so a second launch is intercepted
        // before any other setup runs.
        .plugin(tauri_plugin_single_instance::init(|app, args, _cwd| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show();
                let _ = window.set_focus();
                if let Some(route) = route_from_args(&args) {
                    let script = format!("window.history.pushState(null, '', {}); window.dispatchEvent(new PopStateEvent('popstate')); window.dispatchEvent(new Event('codevisor-route-changed'));", serde_json::to_string(&route).unwrap_or_else(|_| "\"/\"".to_string()));
                    let _ = window.eval(&script);
                }
            }
        }))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .manage(server::ServerManager::default())
        .invoke_handler(tauri::generate_handler![
            server::get_server_config,
            server::server_status,
            server::retry_server
        ])
        .setup(|app| {
            // Spawn/attach the local codevisor server off the main thread; the
            // webview shows a "starting server" state driven by the
            // codevisor://server-state events until this settles.
            let handle = app.handle().clone();
            std::thread::spawn(move || server::ensure_running(&handle));
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running codevisor desktop");
}
