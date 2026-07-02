#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod server;

use tauri::Manager;

fn main() {
    tauri::Builder::default()
        // Must be the first registered plugin so a second launch is intercepted
        // before any other setup runs.
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show();
                let _ = window.set_focus();
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
            // Spawn/attach the local herdman server off the main thread; the
            // webview shows a "starting server" state driven by the
            // herdman://server-state events until this settles.
            let handle = app.handle().clone();
            std::thread::spawn(move || server::ensure_running(&handle));
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running herdman desktop");
}
