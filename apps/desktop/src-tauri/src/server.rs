// Local codevisor server lifecycle: a port of the Swift app's
// LocalCodevisorServer (apps/macos/.../Server/LocalCodevisorServer.swift). The
// server is a durable multi-client daemon shared with the Swift app — same
// port, same database — so both apps see the same workspaces and sessions.
//
// Semantics preserved from the Swift implementation:
// - Health-check first; a healthy server is only replaced when the bundled
//   runtime's VERSION is newer than the running server's version (dev builds
//   have no VERSION file, which disables replacement there).
// - Replacement asks politely over HTTP (POST /v1/shutdown), then signals
//   whatever still listens on the port (SIGTERM via lsof), then respawns.
// - The spawned server is detached (its own process group, output to
//   server.log) and is deliberately NOT terminated when the app exits: it owns
//   durable sessions and clients reconnect to live work.
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, State};

pub const PRODUCTION_PORT: u16 = 49361;
pub const DEVELOPMENT_PORT: u16 = 49362;

const STATE_EVENT: &str = "codevisor://server-state";

pub fn local_server_port() -> u16 {
    // Match the Swift app's variant split so dev builds share the dev server
    // and release builds share the production one.
    if cfg!(debug_assertions) {
        DEVELOPMENT_PORT
    } else {
        PRODUCTION_PORT
    }
}

fn application_support_directory_name() -> &'static str {
    if cfg!(debug_assertions) {
        "Codevisor Development"
    } else {
        "Codevisor"
    }
}

fn application_support_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let dir = PathBuf::from(home)
        .join("Library/Application Support")
        .join(application_support_directory_name());
    let _ = std::fs::create_dir_all(&dir);
    dir
}

fn database_path() -> PathBuf {
    application_support_dir().join("codevisor-server.sqlite")
}

fn log_path() -> PathBuf {
    application_support_dir().join("server.log")
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "state", content = "detail", rename_all = "camelCase")]
pub enum ServerState {
    Idle,
    Starting,
    AlreadyRunning,
    Started,
    Unavailable(String),
}

#[derive(Default)]
pub struct ServerManager {
    state: Mutex<Option<ServerState>>,
}

impl ServerManager {
    fn set(&self, app: &AppHandle, next: ServerState) {
        *self.state.lock().expect("server state lock") = Some(next.clone());
        let _ = app.emit(STATE_EVENT, &next);
    }

    fn get(&self) -> ServerState {
        self.state
            .lock()
            .expect("server state lock")
            .clone()
            .unwrap_or(ServerState::Idle)
    }
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerConfig {
    base_url: String,
    token: Option<String>,
    state: ServerState,
}

#[tauri::command]
pub fn get_server_config(manager: State<'_, ServerManager>) -> ServerConfig {
    ServerConfig {
        base_url: format!("http://127.0.0.1:{}", local_server_port()),
        // Loopback connections are exempt from the server's token auth; the
        // field exists for future remote-machine support.
        token: None,
        state: manager.get(),
    }
}

#[tauri::command]
pub fn server_status(manager: State<'_, ServerManager>) -> ServerState {
    manager.get()
}

#[tauri::command]
pub fn retry_server(app: AppHandle) {
    std::thread::spawn(move || ensure_running(&app));
}

// ---------------------------------------------------------------------------
// Health checks
// ---------------------------------------------------------------------------

fn health_version(port: u16) -> Option<String> {
    let response = ureq::get(&format!("http://127.0.0.1:{port}/v1/health"))
        .timeout(Duration::from_secs(2))
        .call()
        .ok()?;
    let body: serde_json::Value = response.into_json().ok()?;
    if body.get("ok").and_then(|ok| ok.as_bool()) != Some(true) {
        return None;
    }
    Some(
        body.get("version")
            .and_then(|version| version.as_str())
            .unwrap_or_default()
            .to_string(),
    )
}

fn is_healthy(port: u16) -> bool {
    health_version(port).is_some()
}

// ---------------------------------------------------------------------------
// Version comparison (mirrors AppUpdateModel.isVersion(_:newerThan:))
// ---------------------------------------------------------------------------

// Dotted numeric compare: "0.2.0" is newer than "0.1.9". A leading "v" and any
// prerelease suffix ("-beta.1") are ignored.
fn numeric_components(version: &str) -> Vec<u64> {
    let trimmed = version.trim();
    let trimmed = trimmed
        .strip_prefix('v')
        .or_else(|| trimmed.strip_prefix('V'))
        .unwrap_or(trimmed);
    let core = trimmed.split(['-', '+']).next().unwrap_or(trimmed);
    core.split('.')
        .map(|part| part.parse::<u64>().unwrap_or(0))
        .collect()
}

fn is_version_newer(candidate: &str, current: &str) -> bool {
    let lhs = numeric_components(candidate);
    let rhs = numeric_components(current);
    for index in 0..lhs.len().max(rhs.len()) {
        let left = lhs.get(index).copied().unwrap_or(0);
        let right = rhs.get(index).copied().unwrap_or(0);
        if left != right {
            return left > right;
        }
    }
    false
}

// ---------------------------------------------------------------------------
// Runtime resolution (mirrors defaultEntrypoint / defaultNodeExecutable)
// ---------------------------------------------------------------------------

fn bundled_server_target() -> &'static str {
    if cfg!(target_arch = "x86_64") {
        "darwin-x64"
    } else {
        "darwin-arm64"
    }
}

// The bundled runtime directory inside the app's Resources: bundle.resources
// maps resources/server → Resources/server/<target>/{main.js,bin/node,VERSION}.
fn bundled_runtime_dir(app: &AppHandle) -> Option<PathBuf> {
    let resources = app.path().resource_dir().ok()?;
    let candidates = [
        resources.join(format!("server/{}", bundled_server_target())),
        resources.join("server"),
    ];
    candidates.into_iter().find(|candidate| {
        candidate.join("main.js").is_file() && is_executable(&candidate.join("bin/node"))
    })
}

fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .map(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

// Development fallback: walk up from the executable looking for the repo's
// built server (apps/server/dist/main.js), mirroring the Swift #filePath walk.
fn development_entrypoint() -> Option<PathBuf> {
    let mut directory = std::env::current_exe().ok()?.parent()?.to_path_buf();
    for _ in 0..12 {
        let candidate = directory.join("apps/server/dist/main.js");
        if candidate.is_file() {
            return Some(candidate);
        }
        if !directory.pop() {
            break;
        }
    }
    None
}

fn resolve_entrypoint(app: &AppHandle) -> Option<PathBuf> {
    if let Ok(path) = std::env::var("CODEVISOR_SERVER_ENTRYPOINT")
        .or_else(|_| std::env::var("HERDMAN_SERVER_ENTRYPOINT"))
    {
        if !path.is_empty() {
            return Some(PathBuf::from(path));
        }
    }
    if let Some(runtime) = bundled_runtime_dir(app) {
        let entrypoint = runtime.join("main.js");
        if entrypoint.is_file() {
            return Some(entrypoint);
        }
    }
    development_entrypoint()
}

fn resolve_node(app: &AppHandle, resolved_path: &str) -> PathBuf {
    if let Ok(path) = std::env::var("CODEVISOR_NODE").or_else(|_| std::env::var("HERDMAN_NODE")) {
        if !path.is_empty() {
            return PathBuf::from(path);
        }
    }
    if let Some(runtime) = bundled_runtime_dir(app) {
        let bundled = runtime.join("bin/node");
        if is_executable(&bundled) {
            return bundled;
        }
    }
    for candidate in [
        "/opt/homebrew/bin/node",
        "/usr/local/bin/node",
        "/usr/bin/node",
    ] {
        if is_executable(Path::new(candidate)) {
            return PathBuf::from(candidate);
        }
    }
    // Last resort: look the executable up on the resolved login-shell PATH.
    for directory in resolved_path.split(':').filter(|dir| !dir.is_empty()) {
        let candidate = Path::new(directory).join("node");
        if is_executable(&candidate) {
            return candidate;
        }
    }
    PathBuf::from("node")
}

// The version stamped into the bundled runtime next to its entrypoint. None in
// development runs (the repo tree has no VERSION file), which intentionally
// disables the stale-server replacement there.
fn bundled_server_version(entrypoint: &Path) -> Option<String> {
    let version_file = entrypoint.parent()?.join("VERSION");
    let raw = std::fs::read_to_string(version_file).ok()?;
    let trimmed = raw.trim().to_string();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

// ---------------------------------------------------------------------------
// Login-shell environment (mirrors EnvironmentProbe)
// ---------------------------------------------------------------------------

const FALLBACK_PATH_DIRECTORIES: [&str; 6] = [
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin",
];

// Runs the login-shell PATH probe with a hard deadline: an interactive rc
// file (prompt frameworks, nvm hooks) must not hang server startup.
fn probe_login_path(shell: &str) -> Option<String> {
    use std::io::Read;
    use std::process::ChildStdout;

    let mut child = Command::new(shell)
        .args(["-lc", "echo $PATH"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let deadline = std::time::Instant::now() + Duration::from_secs(3);
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => break,
            Ok(Some(_)) => return None,
            Ok(None) => {
                if std::time::Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return None;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(_) => return None,
        }
    }
    let mut stdout: ChildStdout = child.stdout.take()?;
    let mut output = String::new();
    stdout.read_to_string(&mut output).ok()?;
    let trimmed = output.trim().to_string();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

// Finder-launched apps inherit a minimal PATH that excludes Homebrew/nvm/asdf,
// but the server's harness discovery needs the user's real PATH — ask the
// login shell for it, merging in the fallback directories.
fn resolved_login_path() -> String {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string());
    let probed = probe_login_path(&shell);

    let mut directories: Vec<String> = Vec::new();
    if let Some(path) = probed {
        directories.extend(path.split(':').map(str::to_string));
    }
    for fallback in FALLBACK_PATH_DIRECTORIES {
        if !directories.iter().any(|dir| dir == fallback) {
            directories.push(fallback.to_string());
        }
    }
    directories.join(":")
}

// The server's advertised display name: the Mac's name, so a remote client's
// machine list shows "George's MacBook Pro" rather than a generic label.
fn server_display_name() -> String {
    Command::new("/usr/sbin/scutil")
        .args(["--get", "ComputerName"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "Local Codevisor".to_string())
}

// ---------------------------------------------------------------------------
// Stale-server replacement
// ---------------------------------------------------------------------------

fn listening_pids(port: u16) -> Vec<i32> {
    Command::new("/usr/sbin/lsof")
        .args(["-ti", &format!("tcp:{port}"), "-sTCP:LISTEN"])
        .output()
        .ok()
        .map(|output| {
            String::from_utf8_lossy(&output.stdout)
                .lines()
                .filter_map(|line| line.trim().parse::<i32>().ok())
                .collect()
        })
        .unwrap_or_default()
}

fn request_shutdown(port: u16) {
    let _ = ureq::post(&format!("http://127.0.0.1:{port}/v1/shutdown"))
        .timeout(Duration::from_secs(2))
        .call();
}

fn poll_until_unhealthy(port: u16) -> bool {
    for _ in 0..20 {
        if !is_healthy(port) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(150));
    }
    false
}

// Stops a healthy-but-outdated server: politely over HTTP first, then — for
// servers that predate the shutdown endpoint — by signalling whatever still
// listens on the port. Never signals our own process.
fn stop_stale_server(port: u16) {
    request_shutdown(port);
    if poll_until_unhealthy(port) {
        return;
    }
    let own_pid = std::process::id() as i32;
    for pid in listening_pids(port) {
        if pid != own_pid {
            unsafe {
                libc::kill(pid, libc::SIGTERM);
            }
        }
    }
    poll_until_unhealthy(port);
}

// ---------------------------------------------------------------------------
// Spawn + ensure_running
// ---------------------------------------------------------------------------

fn spawn_server(app: &AppHandle, entrypoint: &Path) -> Result<(), String> {
    let port = local_server_port();
    let log_file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path())
        .map_err(|error| format!("could not open server log: {error}"))?;
    let log_err = log_file
        .try_clone()
        .map_err(|error| format!("could not open server log: {error}"))?;

    let path = resolved_login_path();
    let node = resolve_node(app, &path);

    let mut command = Command::new(&node);
    command
        .arg(entrypoint)
        .arg("serve")
        // The server binds every interface so paired remote clients can reach
        // it; only same-machine connections are exempt from its token auth.
        .args(["--host", "0.0.0.0"])
        .args(["--port", &port.to_string()])
        .args(["--db", &database_path().to_string_lossy()])
        .args(["--auth", "token"])
        .args(["--kind", "local"])
        .args(["--name", &server_display_name()])
        // Allow the Tauri webview's browser origin to call the HTTP API
        // (fetch from tauri://localhost is CORS-checked; WS is not). Dev
        // builds load the vite dev server, so its origin is allowed too.
        .args(["--cors-origins", cors_origins()])
        .env("PATH", &path)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log_file))
        .stderr(Stdio::from(log_err));

    // Detach into its own process group so the server outlives this app —
    // it owns durable sessions and clients reconnect to live work.
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }

    command
        .spawn()
        .map(|_child| ())
        .map_err(|error| format!("could not launch {}: {error}", node.display()))
}

fn cors_origins() -> &'static str {
    if cfg!(debug_assertions) {
        "tauri://localhost,http://tauri.localhost,http://localhost:3001"
    } else {
        "tauri://localhost,http://tauri.localhost"
    }
}

fn wait_until_healthy(port: u16) -> bool {
    for _ in 0..40 {
        if is_healthy(port) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    false
}

pub fn ensure_running(app: &AppHandle) {
    let manager = app.state::<ServerManager>();
    let port = local_server_port();
    manager.set(app, ServerState::Starting);

    let entrypoint = resolve_entrypoint(app);

    if let Some(running_version) = health_version(port) {
        // A durable server left behind by an older install keeps serving
        // across upgrades. Replace it only when the bundled runtime is newer;
        // the database lives outside the bundle, so the new runtime picks it
        // up and runs its own migrations.
        let bundled_version = entrypoint
            .as_deref()
            .and_then(bundled_server_version)
            .filter(|bundled| is_version_newer(bundled, &running_version));
        if bundled_version.is_none() {
            manager.set(app, ServerState::AlreadyRunning);
            return;
        }
        stop_stale_server(port);
        if is_healthy(port) {
            // The stale server survived both the shutdown request and the
            // signal; keep using it rather than failing outright.
            manager.set(app, ServerState::AlreadyRunning);
            return;
        }
    }

    let Some(entrypoint) = entrypoint else {
        manager.set(
            app,
            ServerState::Unavailable("Codevisor server entrypoint was not found".to_string()),
        );
        return;
    };

    if let Err(reason) = spawn_server(app, &entrypoint) {
        manager.set(app, ServerState::Unavailable(reason));
        return;
    }

    if wait_until_healthy(port) {
        manager.set(app, ServerState::Started);
    } else {
        manager.set(
            app,
            ServerState::Unavailable(format!(
                "Timed out waiting for Codevisor server. See {}",
                log_path().display()
            )),
        );
    }
}
