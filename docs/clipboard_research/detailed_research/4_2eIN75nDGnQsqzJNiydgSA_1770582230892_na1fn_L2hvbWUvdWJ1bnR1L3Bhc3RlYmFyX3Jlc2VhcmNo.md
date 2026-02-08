# PasteBar Technical Research

## Overview
PasteBar is a free and open-source cross-platform clipboard manager for macOS and Windows. It aims to enhance the copy-paste workflow with unlimited history, advanced organization, and various powerful features.

## Architecture
PasteBar leverages a modern web stack for its user interface and a Rust-based backend for native performance and system integration. The core technologies include:

*   **Backend:** Tauri Apps (Rust), Diesel ORM, Reqwest, Anyhow, Serde, Tokio.
*   **Frontend:** JavaScript (TypeScript), React 19, React Query, Vite, TailwindCSS, Signals, Jotai, Zustand.

This architecture allows for a native-like experience with the flexibility of web technologies.

## Key Features and Implementation Details

### Clipboard Management
*   **Unlimited History:** Stores an unlimited number of copied items.
*   **Searchable History:** Provides a searchable history with support for notes.
*   **Custom Saved Clips:** Allows users to organize and save clips.
*   **Quick-Access Paste Menus:** Facilitates quick pasting of frequently used items.
*   **Organization:** Utilizes collections, tabs, and boards for better organization.

### Privacy & Security
*   **Local Storage:** All clipboard data is stored locally on the user's device.
*   **Lock Screen & Passcode Protection:** Offers security features to protect sensitive data.
*   **PIN-Protected Collections:** Specific collections can be secured with a PIN.
*   **Custom Data Location:** Users can choose where to store their clipboard data, enabling synchronization via cloud storage or shared network drives.

### Data Storage
*   **Database:** Uses SQLite, managed by Diesel ORM (Rust).

### Cross-Platform & Integration
*   **Operating Systems:** Available for macOS (Apple Silicon M1, Intel) and Windows (AMD, ARM).
*   **Backup & Restore:** Provides functionality to export and import the entire clipboard database and images.

## Initial Code Examples / API Usage (Inferred)

*   **Clipboard Access:** The `src-tauri` directory is expected to contain Rust code interacting with the operating system's clipboard APIs. The `Tauri` framework itself provides a `clipboard` plugin, which likely handles the low-level interactions.
*   **Database Interaction:** `Diesel ORM` is used for database operations, suggesting Rust code will define models and interact with the SQLite database for storing clipboard history and other application data.
*   **UI Development:** The `packages/pastebar-app-ui` directory contains the React frontend, where UI components and logic for displaying and interacting with clipboard data are implemented using TypeScript, React, and related libraries.

## Next Steps
Investigate the `src-tauri` directory for specific clipboard access patterns and API usage, and explore how the custom data location and backup/restore features are implemented for synchronization.

## Clipboard Access and Handling (from `src-tauri/src/clipboard/mod.rs`)

PasteBar's core clipboard functionality is implemented in Rust, leveraging several crates for cross-platform compatibility and robust handling of clipboard events and data types.

### Clipboard Access

PasteBar utilizes the `arboard` crate for fundamental clipboard interactions, allowing it to read and write various data types, including text and images. For monitoring clipboard changes, the `clipboard_master` crate is employed. The `ClipboardMonitor` struct, implementing the `ClipboardHandler` trait, contains the `on_clipboard_change` method, which is invoked upon any clipboard modification. This method is central to PasteBar's ability to capture and process new clipboard entries. Platform-specific handling is also evident, with `clipboard_win` being used for Windows to manage diverse data formats and provide finer control over clipboard operations on that operating system.

### Data Handling

Upon a clipboard change, the `on_clipboard_change` method performs several critical steps:

1.  **History Capture Check:** It first verifies if clipboard history capturing is enabled through user settings. If disabled, the event is ignored, preventing unnecessary processing and respecting user preferences.
2.  **Text Extraction:** The `clipboard_manager.read_text()` function is used to extract the text content from the clipboard. The presence of `image::GenericImageView` and `image::{ImageBuffer, RgbaImage}` imports indicates that PasteBar is also capable of handling and processing image data from the clipboard.
3.  **History Management:** A history insert counter is incremented. If this counter reaches a predefined threshold (e.g., 200), it triggers `cron_jobs::run_pending_jobs()`, suggesting background tasks for maintenance or synchronization.
4.  **Text Processing:** Captured text undergoes several processing steps:
    *   **Trimming:** Based on user settings (`isHistoryAutoTrimOnCaputureEnabled`), leading and trailing whitespace can be automatically removed.
    *   **Length Filtering:** Clipboard entries are checked against minimum and maximum length settings (`clipTextMinLength`, `clipTextMaxLength`). Entries falling outside these bounds can be excluded from history.
    *   **Exclusion List:** An exclusion list, configurable by the user (`isExclusionListEnabled`, `historyExclusionList`), allows PasteBar to ignore clipboard content from specific applications or containing certain keywords, enhancing privacy and relevance.

### Concurrency and Settings Management

PasteBar employs `Arc<Mutex<bool>>` and `Arc<Mutex<ClipboardManager>>` for safe, concurrent access to shared resources like the clipboard manager and application state. Application settings are accessed via `app_handle.state::<Mutex<HashMap<String, Setting>>>()`, demonstrating a centralized approach to managing user configurations.

## Synchronization Mechanisms

PasteBar's synchronization strategy is primarily user-driven, relying on the **Custom Data Location** feature. By allowing users to specify the storage location for their clipboard data (e.g., a cloud-synced folder or a shared network drive), PasteBar enables cross-device synchronization through external file synchronization services rather than implementing its own proprietary sync protocol. This approach offers flexibility and leverages existing, robust synchronization solutions.

## Code Examples

```rust
use arboard::{Clipboard, ImageData};
use base64::{engine::general_purpose, Engine as _};
use clipboard_master::{CallbackResult, ClipboardHandler, Master};
use image::GenericImageView;
use image::{ImageBuffer, RgbaImage};
use std::borrow::Cow;
use std::fs::File;
use std::io::Read;
use std::{
  collections::HashMap,
  sync::{Arc, Mutex},
};
use tauri::{self};
use tauri::{
  plugin::{Builder, TauriPlugin},
  Manager, Runtime,
};

// Windows-specific clipboard handling
#[cfg(target_os = "windows")]
use clipboard_win::{formats, get_clipboard};

use active_win_pos_rs::get_active_window;

use crate::cron_jobs;
use crate::models::Setting;
use crate::services::history_service;
use crate::services::utils::debug_output;

#[derive(Debug)]
pub struct LanguageDetectOptions {
  pub should_detect_language: bool,
  pub min_lines_required: usize,
  pub enabled_languages: Vec<String>,
  pub prioritized_languages: Vec<String>,
  pub auto_mask_words_list: Vec<String>,
}

struct ClipboardMonitor<R>
where
  R: Runtime,
{
  app_handle: tauri::AppHandle<R>,
  running: Arc<Mutex<bool>>,
  clipboard_manager: Arc<Mutex<ClipboardManager>>,
}

impl<R> ClipboardMonitor<R>
where
  R: Runtime,
{
  fn new(
    app_handle: tauri::AppHandle<R>,
    running: Arc<Mutex<bool>>,
    clipboard_manager: Arc<Mutex<ClipboardManager>>,
  ) -> Self {
    Self {
      app_handle: app_handle,
      running,
      clipboard_manager,
    }
  }
}

impl<R> ClipboardHandler for ClipboardMonitor<R>
where
  R: Runtime,
{
  fn on_clipboard_change(&mut self) -> CallbackResult {
    let clipboard_manager = self.clipboard_manager.lock().unwrap();
    let app_settings = self.app_handle.state::<Mutex<HashMap<String, Setting>>>();
    let settings_map = app_settings.lock().unwrap();

    if let Some(setting) = settings_map.get("isHistoryEnabled") {
      if let Some(value_bool) = setting.value_bool {
        if !value_bool {
          println!("History capturing is disabled, no event will be send!");
          return CallbackResult::Next;
        }
      }
    }

    let clipboard_text = clipboard_manager.read_text();

    history_service::increment_history_insert_count();

    let current_count = *history_service::HISTORY_INSERT_COUNT.lock().unwrap();

    if current_count >= 200 {
      history_service::reset_history_insert_count();
      cron_jobs::run_pending_jobs();
    }

    let mut do_refresh_clipboard: Option<String> = None;

    let should_auto_star_on_double_copy = settings_map
      .get("isAutoFavoriteOnDoubleCopyEnabled")
      .and_then(|s| s.value_bool)
      .unwrap_or(true);

    let copied_from_app = match get_active_window() {
      Ok(active_window) => Some(active_window.app_name),
      Err(()) => None,
    };

    if let Ok(mut text) = clipboard_text {
      let trim_text_history = settings_map
        .get("isHistoryAutoTrimOnCaputureEnabled")
        .and_then(|s| s.value_bool)
        .unwrap_or(true);

      if trim_text_history {
        text = text.trim().to_string();
      }

      if !text.is_empty() {
        let mut is_excluded = false;

        let text_min_length = settings_map
          .get("clipTextMinLength")
          .and_then(|s| s.value_int)
          .unwrap_or(0) as usize;

        let text_max_length = settings_map
          .get("clipTextMaxLength")
          .and_then(|s| s.value_int)
          .unwrap_or(5000) as usize;

        if text.len() < text_min_length || (text.len() > text_max_length && text_max_length > 0) {
          is_excluded = true;
        }

        if !is_excluded {
          if let Some(setting) = settings_map.get("isExclusionListEnabled") {
            if let Some(value_bool) = setting.value_bool {
              if value_bool {
                let exclusion_list: Vec<String> = settings_map
                  .get("historyExclusionList")
                  .and_then(|s| s.value_text.as_ref())
                  .map_or(Vec::new(), |exclusion_list_text| {
                    exclusion_list_text.lines().map(String::from).collect()
                  });

                if exclusion_list.iter().any(|excluded_app| {
                  copied_from_app
                    .as_ref()
                    .map_or(false, |app_name| app_name.contains(excluded_app))
                }) {
                  is_excluded = true;
                }
              }
            }
          }
        }

        if !is_excluded {
          // Further processing and storage of clipboard content
        }
      }
    }
    CallbackResult::Next
  }
}
```

## Data Storage and Database Interaction (from `src-tauri/src/db.rs`)

PasteBar uses SQLite as its database, managed through the `diesel` ORM in Rust. The `db.rs` file outlines the database connection management, initialization, and configuration.

### Database Connection

A connection pool is established using `r2d2` and `diesel`, ensuring efficient and concurrent database access. The `init_connection_pool` function sets up this pool, and the `DB_POOL_CONNECTION` static variable, wrapped in a `RwLock`, provides global, thread-safe access to it. The connection can be customized with options like enabling WAL (Write-Ahead Logging) mode, enforcing foreign key constraints, and setting a busy timeout, allowing for fine-tuning of database performance and integrity.

### Database Initialization and Migration

The `init` function, called at application startup, is responsible for setting up the database. It determines the appropriate path for the database file, which can be customized by the user. The `diesel_migrations` crate is used to manage database schema migrations, ensuring that the database structure is up-to-date. The `embed_migrations!` macro embeds migration scripts directly into the application binary, simplifying deployment and ensuring that migrations are always available.

### Custom Data Location and Synchronization

The `get_db_path` function is key to PasteBar's synchronization strategy. It retrieves the user-configured database path from the application's settings. If a custom path is set, it uses that path; otherwise, it defaults to a standard location within the application's data directory. This mechanism allows users to place their database in a cloud-synced folder (e.g., Dropbox, Google Drive), effectively enabling cross-device synchronization of their clipboard history.

### Code Example

```rust
use lazy_static::lazy_static;
use once_cell::sync::OnceCell;
use serde::Serialize;
use std::fs;
use std::path::Path;
use std::path::PathBuf;
use std::sync::RwLock;
use std::time::Duration;

use diesel::connection::SimpleConnection;
use diesel::prelude::*;
use diesel::r2d2 as diesel_r2d2;

use crate::services::user_settings_service::load_user_config;
use diesel::sqlite::SqliteConnection;

use diesel_migrations::{embed_migrations, EmbeddedMigrations, MigrationHarness};

const MIGRATIONS: EmbeddedMigrations = embed_migrations!();

type Pool = r2d2::Pool<diesel_r2d2::ConnectionManager<SqliteConnection>>;

#[derive(Serialize)]
pub struct AppConstants<'a> {
  pub app_data_dir: std::path::PathBuf,
  pub app_dev_data_dir: std::path::PathBuf,
  pub app_detect_languages_supported: [&'a str; 23],
}
pub static APP_CONSTANTS: OnceCell<AppConstants> = OnceCell::new();

#[derive(Debug)]
pub struct ConnectionOptions {
  pub enable_wal: bool,
  pub enable_foreign_keys: bool,
  pub busy_timeout: Option<Duration>,
}

lazy_static! {
  pub static ref DB_POOL_CONNECTION: RwLock<Pool> = RwLock::new(init_connection_pool());
}

impl diesel::r2d2::CustomizeConnection<SqliteConnection, diesel::r2d2::Error>
  for ConnectionOptions
{
  fn on_acquire(&self, conn: &mut SqliteConnection) -> Result<(), diesel::r2d2::Error> {
    (|| {
      if self.enable_wal {
        conn.batch_execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")?;
      }
      if self.enable_foreign_keys {
        conn.batch_execute("PRAGMA foreign_keys = ON;")?;
      }
      if let Some(d) = self.busy_timeout {
        conn.batch_execute(&format!("PRAGMA busy_timeout = {};", d.as_millis()))?;
      }
      Ok(())
    })()
    .map_err(diesel::r2d2::Error::QueryError)
  }
}

fn init_connection_pool() -> Pool {
  let db_path = get_db_path();

  let manager = diesel_r2d2::ConnectionManager::<SqliteConnection>::new(db_path);
  r2d2::Pool::builder()
    .connection_customizer(Box::new(ConnectionOptions {
      enable_wal: false,
      enable_foreign_keys: false,
      busy_timeout: Some(Duration::from_secs(3)),
    }))
    .build(manager)
    .expect("Failed to create db pool.")
}

pub fn get_db_path() -> String {
    // ... implementation to get db path from settings ...
    // Simplified for brevity
    let config = load_user_config();
    config.db_path
}
```

### Database Initialization and Migration

The `init` function, called at application startup, is responsible for setting up the database. It determines the appropriate path for the database file, which can be customized by the user. The `diesel_migrations` crate is used to manage database schema migrations, ensuring that the database structure is up-to-date. The `embed_migrations!` macro embeds migration scripts directly into the application binary, simplifying deployment and ensuring that migrations are always available.

### Custom Data Location and Synchronization

The `get_db_path` function is key to PasteBar's synchronization strategy. It retrieves the user-configured database path from the application's settings. If a custom path is set, it uses that path; otherwise, it defaults to a standard location within the application's data directory. This mechanism allows users to place their database in a cloud-synced folder (e.g., Dropbox, Google Drive), effectively enabling cross-device synchronization of their clipboard history.

### Code Example (Continued)

```rust
pub fn get_db_path() -> String {
    // ... implementation to get db path from settings ...
    // Simplified for brevity
    let config = load_user_config();
    config.db_path
}

pub fn init(app: &mut tauri::App) {
  let config = app.config().clone();

  let resource_path = app.path_resolver().resource_dir().unwrap();

  #[cfg(debug_assertions)]
  let local_dev_path = resource_path
    .parent()
    .unwrap()
    .parent()
    .unwrap()
    .parent()
    .unwrap();

  if cfg!(debug_assertions) {
    println!(
      "Appdata path is {}",
      tauri::api::path::app_data_dir(&config)
        .expect("failed to retrieve app_data_dir")
        .display()
    );

    #[cfg(debug_assertions)]
    println!("Local App dev path is {}", &local_dev_path.display());
  }

  ensure_dir_exists(&tauri::api::path::app_data_dir(&config).unwrap()); // canonicalize will work only if path exists

  let _ = APP_CONSTANTS.set(AppConstants {
    #[cfg(not(debug_assertions))]
    app_dev_data_dir: std::path::PathBuf::from(resource_path),
    #[cfg(debug_assertions)]
    app_dev_data_dir: std::path::PathBuf::from(local_dev_path),
    app_data_dir: tauri::api::path::app_data_dir(&config)
      .expect("failed to retrieve app_data_dir")
      .canonicalize()
      .expect("Failed to canonicalize app_data_dir"),
    app_detect_languages_supported: [
      "c",
      "cpp",
      "csharp",
      "css",
      "docker",
      "dart",
      "go",
      "html",
      "java",
      "javascript",
      "jsx",
      "json",
      "kotlin",
      "markdown",
      "php",
      "python",
    ],
  });

  // Run migrations
  let mut connection = DB_POOL_CONNECTION.write().unwrap().get().unwrap();
  connection
    .run_pending_migrations(MIGRATIONS)
    .expect("Error running migrations");
}

pub fn get_config_file_path() -> PathBuf {
  if cfg!(debug_assertions) {
    let app_dir = APP_CONSTANTS
      .get()
      .expect("APP_CONSTANTS not initialized")
      .app_dev_data_dir
      .clone();
    if cfg!(target_os = "macos") {
      PathBuf::from(format!(
        "{}/pastebar_settings.yaml",
        adjust_canonicalization(app_dir)
      ))
    } else if cfg!(target_os = "windows") {
      PathBuf::from(format!(
        "{}\\pastebar_settings.yaml",
        adjust_canonicalization(app_dir)
      ))
    } else {
      PathBuf::from(format!(
        "{}/pastebar_settings.yaml",
        adjust_canonicalization(app_dir)
      ))
    }
  } else {
    // Release mode
    let app_data_dir = APP_CONSTANTS.get().unwrap().app_data_dir.clone();
    let data_dir = app_data_dir.as_path();

    if cfg!(target_os = "macos") {
      PathBuf::from(format!(
        "{}/pastebar_settings.yaml",
        adjust_canonicalization(data_dir)
      ))
    } else if cfg!(target_os = "windows") {
      PathBuf::from(format!(
        "{}\\pastebar_settings.yaml",
        adjust_canonicalization(data_dir)
      ))
    } else {
      PathBuf::from(format!(
        "{}/pastebar_settings.yaml",
        adjust_canonicalization(data_dir)
      ))
    }
  }
}
```
