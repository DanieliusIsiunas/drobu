# CopyQ Cross-Platform Implementation: Technical Details

## Introduction

This document provides a comprehensive overview of CopyQ's cross-platform implementation, focusing on its use of the Qt framework, clipboard monitoring mechanisms, and data storage strategies. CopyQ is an advanced clipboard manager designed for Linux, Windows, and macOS, offering features such as storing various data formats, quick browsing, and filtering of clipboard history [1].

## Implementation Approaches and Architecture

CopyQ is primarily written in C++17 and leverages the **Qt framework** for its cross-platform capabilities [1]. The application's architecture is modular, involving several distinct processes to manage its functionalities efficiently [1]:

*   **Main GUI Application**: This acts as the server, establishing a local server for communication with other CopyQ processes. Multiple GUI application processes can run concurrently, each with a unique session name [1].
*   **Clipboard Monitor**: This crucial component operates as a separate process to prevent blocking the GUI, especially since Qt's clipboard access requires the main GUI thread. It is responsible for executing automatic clipboard commands and is restarted if it becomes unresponsive [1].
*   **Menu Command Filter**: This process dynamically enables or hides custom menu items based on defined filters [1].
*   **Display Command**: Executes display-related commands as needed [1].
*   **Clipboard and X11 Selection Owner and Synchronization**: Provides clipboard data and is launched on demand [1].
*   **Multiple Clients**: These encompass any user-triggered actions from the Action dialog or commands initiated via menus, automatic triggers, or global shortcuts [1].

## Qt Framework Usage

The choice of the Qt framework is central to CopyQ's cross-platform nature. Qt provides the necessary abstractions to develop a single codebase that runs natively across different operating systems. The application's source code can be built using CMake [1].

## Clipboard Monitoring

Clipboard monitoring is handled by a dedicated, separate process. This design choice is critical for maintaining GUI responsiveness, as direct clipboard access within the main GUI thread in Qt can lead to blocking issues. The monitor process is launched at application startup and is designed to be resilient, restarting if it fails to respond to keep-alive requests [1].

## Data Storage Mechanisms

By default, CopyQ automatically stores any text or image content copied to the clipboard. Users have the option to completely disable automatic clipboard storage or to prevent storing content from specific windows by matching their titles [2].

**Key aspects of data storage include** [2]:

*   **Location**: Data from all tabs is stored in the configuration directory.
*   **Encryption**: By default, stored data is unencrypted unless the encryption feature is explicitly enabled.
*   **Privacy**: CopyQ does not collect or transmit any user data over the network.

## Security and Privacy Features

CopyQ offers several features to enhance security and privacy related to clipboard data [2]:

*   **Disabling Automatic Storage**: Users can prevent CopyQ from automatically saving clipboard content.
*   **Content Filtering**: The application can be configured to ignore content copied from specific applications (e.g., password managers) based on window titles.
*   **Clipboard Content Visibility**: Options are available to disable the display of current clipboard content in the GUI, main window title, tray tooltips, and notifications.
*   **Restricted Clipboard Access**: Commands like “Clear Clipboard After Interval” can be used to limit the duration for which data remains accessible in the clipboard.

## Code Examples and Patterns

CopyQ utilizes **Qt Script** (a JavaScript-like language) for scripting and extending its functionality. Scripts can be executed via the `copyq` command-line utility, allowing for dynamic interaction with the application [1].

**Example of a scriptable proxy method call** [1]:

```cpp
bool ScriptableProxy::loadTab(const QString &tabName)
{
    // This section is wrapped in an macro so to remove duplicate code.
    if (!m_inMainThread) {
        // Callable object just wraps the lambda so it's possible to send it to a slot.
        auto callable = createCallable([&]{ return loadTab(tabName); });

        m_inMainThread = true;
        QMetaObject::invokeMethod(m_wnd, "invoke", Qt::BlockingQueuedConnection, Q_ARG(Callable*, &callable));
        m_inMainThread = false;

        return callable.result();
    }

    // Now it's possible to call method on an object in main thread.
    return m_wnd->loadTab(tabName);
}
```

This C++ code snippet demonstrates how `ScriptableProxy` handles calls from non-main threads by invoking a slot on a `QObject` in the main thread, ensuring thread-safe operations within the Qt environment [1].

## Platform-dependent Code

To manage platform-specific implementations, CopyQ organizes platform-dependent code in `src/platform`. This approach minimizes the use of preprocessor directives (`#if`) in common code. Each supported platform implements a `PlatformNativeInterface` and `platformNativeInterface()`, which handle tasks such as creating Qt application objects, clipboard handling, window focusing, system path retrieval, autostart options, and global shortcuts [1].

## Plugins

CopyQ supports plugins, which are built as dynamic libraries and loaded at runtime from a platform-dependent directory. Plugins implement interfaces defined in `src/item/itemwidget.h`, allowing for extensible functionality [1].

## References

[1] [Source Code Overview — CopyQ documentation](https://copyq.readthedocs.io/en/latest/source-code-overview.html)
[2] [Security — CopyQ documentation](https://copyq.readthedocs.io/en/latest/security.html)
