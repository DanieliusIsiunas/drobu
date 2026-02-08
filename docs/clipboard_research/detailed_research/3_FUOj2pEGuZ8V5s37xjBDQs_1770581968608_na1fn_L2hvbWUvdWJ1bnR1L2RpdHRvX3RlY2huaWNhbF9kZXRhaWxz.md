```cpp
#include "stdafx.h"
#include "CP_Main.h"
#include "MainFrm.h"
#include "Misc.h"
#include ".\cp_main.h"
#include "server.h"
#include "Client.h"
#include "InternetUpdate.h"
#include <io.h>
#include "Path.h"
#include "Clip_ImportExport.h"
#include "HyperLink.h"
#include "OptionsSheet.h"
#include "DittoCopyBuffer.h"
#include "SendKeys.h"
#include "MainTableFunctions.h"
#include "ShowTaskBarIcon.h"

#ifdef _DEBUG
#define new DEBUG_NEW
#undef THIS_FILE
static char THIS_FILE[] = __FILE__;
#endif

class DittoCommandLineInfo : public CCommandLineInfo
{
public:
	DittoCommandLineInfo()
	{
		m_bDisconnect = FALSE;
		m_bConnect = FALSE;
		m_bU3 = FALSE;
		m_bU3Stop = FALSE;
		m_bU3Install = FALSE;
	}

 	virtual void ParseParam(const TCHAR* pszParam, BOOL bFlag, BOOL bLast)
 	{
  		if(bFlag)
  		{
  			if(STRICMP(pszParam, _T("Connect")) == 0)
  			{
  				m_bConnect = TRUE;
  			}
  			else if(STRICMP(pszParam, _T("Disconnect")) == 0)
  			{
  				m_bDisconnect = TRUE;
  			}
  			else if(STRICMP(pszParam, _T("U3")) == 0)
  			{
  				m_bU3 = TRUE;
  			}
  			else if(STRICMP(pszParam, _T("U3appStop")) == 0)
  			{
  				m_bU3Stop = TRUE;
  			}
  			else if(STRICMP(pszParam, _T("U3Install")) == 0)
  			{
  				m_bU3Install = TRUE;
  			}
  		}
 
		CCommandLineInfo::ParseParam(pszParam, bFlag, bLast);
 	}

	BOOL m_bDisconnect;
	BOOL m_bConnect;
	BOOL m_bU3;
	BOOL m_bU3Stop;
	BOOL m_bU3Install;
};

CCP_MainApp theApp;

BEGIN_MESSAGE_MAP(CCP_MainApp, CWinApp)
	//{{AFX_MSG_MAP(CCP_MainApp)
		// NOTE - the ClassWizard will add and remove mapping macros here.
		//    DO NOT EDIT what you see in these blocks of generated code!
	//}}AFX_MSG_MAP
END_MESSAGE_MAP()

CCP_MainApp::CCP_MainApp()
{
	theApp.m_activeWnd.TrackActiveWnd(NULL);

	m_bAppRunning = false;
	m_bAppExiting = false;
	m_connectOnStartup = -1;
	m_MainhWnd = NULL;
	m_pMainFrame = NULL;

	m_bShowingQuickPaste = false;

	m_IC_bCopy = false;

	m_GroupDefaultID = 0;
	m_GroupID = -1;
	m_GroupParentID = 0;
	m_GroupText = "History";
	m_FocusID = -1;

	m_bAsynchronousRefreshView = true;

	m_lClipsSent = 0;
	m_lClipsRecieved = 0;
	m_oldtStartUp = COleDateTime::GetCurrentTime();

	m_bExitServerThread = false;

	m_lLastGoodIndexForNextworkPassword = -2;

	m_RTFFormat = ::RegisterClipboardFormat(_T("Rich Text Format"));
	m_HTML_Format = ::RegisterClipboardFormat(_T("HTML Format"));
	m_PingFormat = ::RegisterClipboardFormat(_T("Ditto Ping Format"));
	m_cfIgnoreClipboard = ::RegisterClipboardFormat(_T("Clipboard Viewer Ignore"));
	m_cfDelaySavingData = ::RegisterClipboardFormat(_T("Ditto Delay Saving Data"));
	m_RemoteCF_HDROP = ::RegisterClipboardFormat(_T("Ditto Remote CF_HDROP"));
}

CCP_MainApp::~CCP_MainApp()
{
	
}

BOOL CCP_MainApp::InitInstance()
{
	LoadLibrary(TEXT("riched20.dll"));

	AfxEnableControlContainer();
	AfxOleInit();
	AfxInitRichEditEx();
	afxAmbientActCtx = FALSE; 

	DittoCommandLineInfo cmdInfo;
	ParseCommandLine(cmdInfo);

	//if starting from a u3 device we will pass in -U3Start
	if(cmdInfo.m_bU3)
		g_Opt.m_bU3 = cmdInfo.m_bU3 ? TRUE : FALSE;

	g_Opt.LoadSettings();

	if(cmdInfo.m_strFileName.IsEmpty() == FALSE)
	{
		try
		{
			g_Opt.m_bEnableDebugLogging = g_Opt.GetEnableDebugLogging();

			CClip_ImportExport Clip;
			CppSQLite3DB db;
			db.open(cmdInfo.m_strFileName);

			CClip_ImportExport clip;
			if(clip.ImportFromSqliteDB(db, false, true))
			{
				ShowCommandLineError("Ditto", theApp.m_Language.GetString("Importing_Good", "Clip placed on clipboard"));
			}
			else
			{
				ShowCommandLineError("Ditto", theApp.m_Language.GetString("Error_Importing", "Error importing exported clip"));
			}
		}
		catch (CppSQLite3Exception& e)
		{
			ASSERT(FALSE);

			CString csError;
			csError.Format(_T("%s - Exception - %d - %s"), theApp.m_Language.GetString("Error_Parsing", "Error parsing exported clip"), e.errorCode(), e.errorMessage());
			ShowCommandLineError("Ditto", csError);
		}	

		return FALSE;
	}
	else if(cmdInfo.m_bConnect || cmdInfo.m_bDisconnect)
	{
		//First get the saved hwnd and send it a message
		//If ditt is running then this will return 1, meening the running ditto process
		//handled this message
		//If it didn't handle the message(ditto is not running) then startup this processes of ditto 
		//disconnected from the clipboard
		LRESULT ret = 0;
		HWND hWnd = (HWND)CGetSetOptions::GetMainHWND();
		if(hWnd)
		{
			ret = ::SendMessage(hWnd, WM_SET_CONNECTED, cmdInfo.m_bConnect, cmdInfo.m_bDisconnect);
		}

		//passed off to the running instance of ditto, exit this instance
		if(ret == 1)
		{
			return FALSE;
		}
		
		if(cmdInfo.m_bConnect)
		{
			m_connectOnStartup = TRUE;
		}
		else if(cmdInfo.m_bDisconnect)
		{
			m_connectOnStartup = FALSE;
		}
	}

	CInternetUpdate update;

	long lRunningVersion = update.GetRunningVersion();
	CString cs = update.GetVersionString(lRunningVersion);
	cs.Insert(0, _T("InitInstance  -  Running Version - "));
	Log(cs);

	CString csMutex("Ditto Is Now Running");
	if(g_Opt.m_bU3)
	{
		//If running from a U3 device then allow other ditto's to run
		//only prevent Ditto from running from the same device
		csMutex += " ";
		csMutex += GETENV(_T("U3_DEVICE_SERIAL"));
	}
	else if(g_Opt.GetIsPortableDitto())
	{
		csMutex += " ";
		csMutex += g_Opt.GetExeFileName();
	}

	m_hMutex = CreateMutex(NULL, FALSE, csMutex);
	DWORD dwError = GetLastError();
	if(dwError == ERROR_ALREADY_EXISTS)
	{
		HWND hWnd = (HWND)CGetSetOptions::GetMainHWND();
		if(hWnd)
			::SendMessage(hWnd, WM_SHOW_TRAY_ICON, TRUE, TRUE);

		return TRUE;
	}

	CString csFile = CGetSetOptions::GetLanguageFile();
	if(m_Language.LoadLanguageFile(csFile) == false)
	{
		CString cs;
		cs.Format(_T("Error loading language file - %s - \n\n%s"), csFile, m_Language.m_csLastError);
		Log(cs);

		m_Language.LoadLanguageFile(_T("English.xml"));
	}

	//The first time we run Ditto on U3 show a web page about ditto
	if(g_Opt.m_bU3)
	{
		if(FileExists(CGetSetOptions::GetDBPath()) == FALSE)
		{
			CString csFile = CGetSetOptions::GetPath(PATH_HELP);
			csFile += "U3_Install.htm";
			CHyperLink::GotoURL(csFile, SW_SHOW);
		}
	}

	int nRet = CheckDBExists(CGetSetOptions::GetDBPath());
	if(nRet == FALSE)
	{
		AfxMessageBox(theApp.m_Language.GetString("Error_Opening_Database", "Error Opening Database."));
		return FALSE;
	}

	CMainFrame* pFrame = new CMainFrame;
	m_pMainWnd = m_pMainFrame = pFrame;

	pFrame->LoadFrame(IDR_MAINFRAME, WS_OVERLAPPEDWINDOW | FWS_ADDTOTITLE, NULL, NULL);
	pFrame->ShowWindow(SW_SHOW);
	pFrame->UpdateWindow();

	return TRUE;
}

void CCP_MainApp::AfterMainCreate()
{
	m_MainhWnd = m_pMainFrame->m_hWnd;
	ASSERT( ::IsWindow(m_MainhWnd) );
	g_Opt.SetMainHWND((long)m_MainhWnd);

	//Save the HWND so the stop app can send us a close message
	if(g_Opt.m_bU3)
	{
		CGetSetOptions::WriteU3Hwnd(m_MainhWnd);
	}

	g_HotKeys.Init(m_MainhWnd);

	// create hotkeys here.  They are automatically deleted on exit
	m_pDittoHotKey = new CHotKey(CString("DittoHotKey"), 704); //704 is ctrl-tilda

	m_pPosOne = new CHotKey("Position1", 0, true);
	m_pPosTwo = new CHotKey("Position2", 0, true);
	m_pPosThree = new CHotKey("Position3", 0, true);
	m_pPosFour = new CHotKey("Position4", 0, true);
	m_pPosFive = new CHotKey("Position5", 0, true);
	m_pPosSix = new CHotKey("Position6", 0, true);
	m_pPosSeven = new CHotKey("Position7", 0, true);
	m_pPosEight = new CHotKey("Position8", 0, true);
	m_pPosNine = new CHotKey("Position9", 0, true);
	m_pPosTen = new CHotKey("Position10", 0, true);

	m_pCopyBuffer1 = new CHotKey("CopyBufferCopyHotKey_0", 0, true);
	m_pPasteBuffer1 = new CHotKey("CopyBufferPasteHotKey_0", 0, true);
	m_pCutBuffer1 = new CHotKey("CopyBufferCutHotKey_0", 0, true);
	
	m_pCopyBuffer2 = new CHotKey("CopyBufferCopyHotKey_1", 0, true);
	m_pPasteBuffer2 = new CHotKey("CopyBufferPasteHotKey_1", 0, true);
	m_pCutBuffer2 = new CHotKey("CopyBufferCutHotKey_1", 0, true);

	m_pCopyBuffer3 = new CHotKey("CopyBufferCopyHotKey_2", 0, true);
	m_pPasteBuffer3 = new CHotKey("CopyBufferPasteHotKey_2", 0, true);
	m_pCutBuffer3 = new CHotKey("CopyBufferCutHotKey_2", 0, true);

	m_pTextOnlyPaste = new CHotKey("TextOnlyPaste", 0, true);

	LoadGlobalClips();

	g_HotKeys.RegisterAll();
	StartCopyThread();
	StartStopServerThread();

#ifdef UNICODE
	m_Addins.LoadAll();
#endif
	
	m_bAppRunning = true;
}

void CCP_MainApp::LoadGlobalClips()
{
	try
	{
		CppSQLite3Query q = m_db.execQuery(_T("SELECT lID, lShortCut, mText FROM Main WHERE lShortCut > 0 AND globalShortCut = 1"));

		while(q.eof() == false)
		{
			int id = q.getIntField(_T("lID"));
			int shortcut = q.getIntField(_T("lShortCut"));
			CString desc = q.getStringField(_T("mText"));

			//Constructor will add to a global list and free
			CHotKey* globalHotKey = new CHotKey(desc, shortcut, true);
			if(globalHotKey != NULL)
			{
				globalHotKey->m_clipId = id;
			}

			q.nextRow();
		}
	}
	CATCH_SQLITE_EXCEPTION
}

void CCP_MainApp::StartStopServerThread()
{
	if(CGetSetOptions::GetDisableRecieve() == FALSE && g_Opt.GetAllowFriends())
	{
		AfxBeginThread(MTServerThread, m_MainhWnd);
	}
	else
	{
		m_bExitServerThread = true;
		closesocket(theApp.m_sSocket);
	}
}

void CCP_MainApp::StopServerThread()
{
	m_bExitServerThread = true;
	closesocket(theApp.m_sSocket);
}

void CCP_MainApp::BeforeMainClose()
{
	ASSERT( m_bAppRunning && !m_bAppExiting );
	m_bAppRunning = false;
	m_bAppExiting = true;
	g_HotKeys.UnregisterAll();
	StopServerThread();
	StopCopyThread();
}

void CCP_MainApp::StartCopyThread()
{
	ASSERT( m_MainhWnd );
	CClipTypes* pTypes = LoadTypesFromDB();
	// initialize to:
```

## Clipboard Data Handling and Storage

Ditto utilizes the Windows clipboard API extensively for capturing and managing clipboard data. The `Clip.cpp` file provides insights into the core mechanisms:

### Windows API Integration

Ditto interacts with the Windows clipboard through the `COleDataObjectEx` class, which appears to be a wrapper around OLE data objects. Key Windows API functions and concepts observed include:

*   `RegisterClipboardFormat()`: Used to register custom clipboard formats, such as `"Rich Text Format"`, `"HTML Format"`, `"Ditto Ping Format"`, `"Clipboard Viewer Ignore"`, and `"Ditto Delay Saving Data"`. These custom formats allow Ditto to manage its internal state and communicate with other instances or components.
*   `GlobalAlloc()` and `GlobalFree()`: Employed for managing global memory handles (`HGLOBAL`) when retrieving data from the clipboard. This is a standard practice for handling clipboard data in Windows applications.
*   `IsClipboardFormatAvailable()`: Checks for the presence of specific clipboard formats, allowing Ditto to conditionally process or ignore clipboard content (e.g., `m_cfIgnoreClipboard` to prevent saving certain clips).
*   `SendMessage()`: Used in `CP_Main.cpp` to communicate with other running instances of Ditto, for example, to connect or disconnect from the clipboard, or to show the tray icon.

### C++ Implementation Details

The `CClip` class represents a single clipboard entry and can hold multiple `CClipFormat` objects, each corresponding to a different data format (e.g., text, HTML, image). The `LoadFromClipboard` method in `CClip` is responsible for populating a `CClip` object with data from the system clipboard. This involves:

1.  **Attaching to the Clipboard**: `COleDataObjectEx::AttachClipboard()` is called to gain access to the current clipboard content.
2.  **Format Enumeration**: Ditto iterates through available clipboard formats, prioritizing those it is configured to save.
3.  **Data Retrieval**: For each available format, `COleDataObjectEx::GetGlobalData()` is used to retrieve the data as a global memory handle.
4.  **Description Extraction**: The `SetDescFromText` and `SetDescFromType` methods attempt to generate a human-readable description for the clip, often from text formats or by inferring from the format type (e.g., "Copied File - ").

### Database Storage Mechanisms

Ditto uses **SQLite** as its primary database for storing clipboard history. Evidence for this includes:

*   Inclusion of `sqlite/CppSQLite3.h` in `Clip.cpp` and `CP_Main.cpp`.
*   The `InitInstance()` method in `CP_Main.cpp` demonstrates opening an SQLite database file (`CppSQLite3DB db; db.open(cmdInfo.m_strFileName);`).
*   The `LoadGlobalClips()` function in `CP_Main.cpp` executes SQL queries (`m_db.execQuery("SELECT lID, lShortCut, mText FROM Main WHERE lShortCut > 0 AND globalShortCut = 1")`) to retrieve stored clips.
*   The `Ditto/sqlite` directory contains `sqlite3.c`, `sqlite3.h`, and `sqlite3ext.h`, which are core SQLite library files.

The `Main` table in the SQLite database appears to store clip metadata, including `lID` (clip ID), `lShortCut` (shortcut key), and `mText` (clip description). The actual clipboard data for various formats is likely stored in associated tables or as BLOBs within the database, linked by the clip ID.

### Code Examples

```cpp
// From CP_Main.cpp - Registering custom clipboard formats
m_RTFFormat = ::RegisterClipboardFormat(_T("Rich Text Format"));
m_HTML_Format = ::RegisterClipboardFormat(_T("HTML Format"));
m_PingFormat = ::RegisterClipboardFormat(_T("Ditto Ping Format"));
m_cfIgnoreClipboard = ::RegisterClipboardFormat(_T("Clipboard Viewer Ignore"));
m_cfDelaySavingData = ::RegisterClipboardFormat(_T("Ditto Delay Saving Data"));
m_RemoteCF_HDROP = ::RegisterClipboardFormat(_T("Ditto Remote CF_HDROP"));

// From CP_Main.cpp - Opening SQLite database
CppSQLite3DB db;
db.open(cmdInfo.m_strFileName);

// From CP_Main.cpp - Executing a query to load global clips
CppSQLite3Query q = m_db.execQuery(_T("SELECT lID, lShortCut, mText FROM Main WHERE lShortCut > 0 AND globalShortCut = 1"));

// From Clip.cpp - Loading data from clipboard
bool CClip::LoadFromClipboard(CClipTypes* pClipTypes)
{
    COleDataObjectEx oleData;
    // ... (checks for custom formats)
    if(!oleData.AttachClipboard())
    {
        Log(_T("failed to attache to clipboard, skipping this clipboard change"));
        ASSERT(0); // does this ever happen?
        return false;
    }
    // ... (iterates through formats and retrieves data)
    cf.m_hgData = oleData.GetGlobalData(cf.m_cfType);
    // ...
}
```

## UI/UX Design Patterns and System Integration

Ditto's user interface and experience are designed for efficiency and non-intrusiveness, leveraging deep integration with the Windows operating system. The `MainFrm.cpp` file, which implements the main application window (`CMainFrame`), reveals several key design patterns:

### System Tray Integration

Ditto operates primarily as a background application, accessible via a system tray icon. The `CMainFrame::OnCreate` function initializes this behavior:

*   A tray icon is created using `m_TrayIcon.Create`.
*   The main application window is minimized to the tray (`m_TrayIcon.MinimiseToTray`), indicating that the primary interaction is not through a traditional visible window.

### Hotkey-Driven Interaction

A significant aspect of Ditto's UI/UX is its reliance on hotkeys for rapid access and manipulation of clipboard history. The `OnHotKey` message handler demonstrates this extensively:

*   **Quick Paste Window**: A global hotkey (e.g., `Ctrl + ``) triggers the display of a quick paste window (`m_quickPaste.ShowQPasteWnd`), which is the central interface for browsing and selecting clipboard entries.
*   **Positional Pasting**: Dedicated hotkeys (`m_pPosOne` to `m_pPosTen`) allow users to paste specific historical clipboard entries directly.
*   **Copy Buffers**: Hotkeys are also used to manage multiple copy buffers (`m_pCopyBuffer1`, `m_pPasteBuffer1`, `m_pCutBuffer1`), enabling advanced clipboard operations.

### Transparent Main Window and Quick Paste Window

The `CMainFrame` itself is made transparent (`m_Transparency.SetTransparent(m_hWnd, 0, true)`) and initially hidden. This suggests that the main window acts as a hidden host for other UI components, particularly the `QPasteWnd` (Quick Paste Window), which is likely a separate, pop-up style window that appears on demand.

### Focus Tracking for Seamless Pasting

To ensure that pasted content goes to the correct application, Ditto actively tracks the currently focused window:

*   It uses either a hook DLL (`focusdll\focusdll.h` and `MonitorFocusChanges`) or a polling timer (`SetTimer(ACTIVE_WINDOW_TIMER)`) to detect changes in the active window.
*   The `theApp.m_activeWnd.TrackActiveWnd(NULL)` call before showing the quick paste window ensures that Ditto knows which window to paste into.

### Windows API Usage for UI/UX

Beyond clipboard-specific APIs, `MainFrm.cpp` utilizes various Windows API functions for general UI management:

*   **Window Creation and Manipulation**: Functions like `MoveWindow`, `SetWindowText`, `AfxGetApp()->LoadIcon`, and `AfxRegisterClass` are used for the fundamental aspects of window creation, styling, and management.
*   **Timers**: `SetTimer` is employed for scheduling background tasks, such as automatically hiding the tray icon after a period, removing old remote copies, and periodically cleaning up old clipboard entries.
*   **Message Handling**: The extensive use of `BEGIN_MESSAGE_MAP` and `ON_MESSAGE` macros highlights Ditto's event-driven architecture, allowing it to respond to system events (e.g., `WM_HOTKEY`, `WM_CLIPBOARD_COPIED`) and internal messages (`WM_FOCUS_CHANGED`, `WM_SHOW_TRAY_ICON`).

These elements collectively contribute to Ditto's reputation as a powerful and efficient clipboard manager that integrates deeply with the Windows environment to provide a seamless user experience.

## Performance Considerations and Configurable Options

Ditto offers a wide range of configurable options that allow users to fine-tune its behavior, directly impacting performance, memory usage, and overall user experience. The `Options.h` file defines many of these settings, which are managed through the `CGetSetOptions` class.

### History Management and Data Retention

To manage performance and storage, especially with large clipboard histories, Ditto provides several settings:

*   `SetMaxEntries()` and `GetMaxEntries()`: These functions control the maximum number of clipboard entries stored in the database. Limiting this number helps prevent the database from growing excessively large, which could impact query performance and disk space usage.
*   `SetExpiredEntries()` and `GetExpiredEntries()`: These likely relate to the automatic removal of old clipboard entries after a certain period, further managing the size of the history.
*   `SetCheckForMaxEntries()` and `GetCheckForMaxEntries()`: Enable or disable the checking mechanism for maximum entries.
*   `SetCheckForExpiredEntries()` and `GetCheckForExpiredEntries()`: Enable or disable the checking mechanism for expired entries.
*   `SetMaxClipSizeInBytes()` and `GetMaxClipSizeInBytes()`: This crucial setting (`m_lMaxClipSizeInBytes`) allows users to limit the size of individual clipboard entries. Large clips (e.g., high-resolution images or extensive formatted text) can consume significant memory and storage. By limiting their size, Ditto can prevent performance degradation and excessive resource consumption.

### Clipboard Processing Delays

Ditto incorporates delays in its clipboard processing to ensure compatibility and smooth operation with other applications:

*   `SetSaveClipDelay()` and `GetSaveClipDelay()` (`m_dwSaveClipDelay`): This setting controls the delay before saving a clipboard entry. This can be important to avoid conflicts with applications that temporarily place data on the clipboard.
*   `SetProcessDrawClipboardDelay()` and `GetProcessDrawClipboardDelay()` (`m_lProcessDrawClipboardDelay`): This delay likely pertains to how quickly Ditto processes `WM_DRAWCLIPBOARD` messages, which are sent when the clipboard content changes. A delay can prevent rapid, successive clipboard changes from overwhelming the application.
*   `SetDittoRestoreClipboardDelay()` and `GetDittoRestoreClipboardDelay()`: This delay is used when Ditto restores the clipboard content, potentially after its own internal operations.

### Network and Synchronization Performance

Ditto supports network synchronization of clipboard data, and several options relate to its performance and security:

*   `MAX_SEND_CLIENTS`: Defines the maximum number of clients to which clipboard data can be sent.
*   `SetNetworkPassword()` and `GetNetworkPassword()`: While primarily a security feature, the use of network passwords and encryption can have a minor impact on performance due to the overhead of cryptographic operations.
*   `SetLogSendReceiveErrors()` and `GetLogSendReceiveErrors()`: Controls whether errors during network send/receive operations are logged, which can be useful for debugging performance issues.

### UI Responsiveness

Several options are designed to improve the responsiveness of the user interface:

*   `SetFindAsYouType()` and `GetFindAsYouType()`: Enabling 
the "Find As You Type" feature (`m_bFindAsYouType`) can significantly enhance the user experience by providing immediate search results as the user types, but it requires efficient search algorithms and database indexing to avoid UI lag.

### Other Performance-Related Options

*   `SetAllowDuplicates()` and `GetAllowDuplicates()`: Controls whether duplicate clipboard entries are saved. Disabling duplicates can reduce database size and improve search performance.
*   `SetUpdateTimeOnPaste()` and `GetUpdateTimeOnPaste()`: Determines if the timestamp of a clip is updated upon pasting. This might have a minor impact on database write operations.
*   `SetDrawThumbnail()` and `GetDrawThumbnail()` (`m_bDrawThumbnail`): Controls whether thumbnails of images or other rich content are drawn in the quick paste window. Generating and displaying thumbnails can be resource-intensive, especially for a large number of clips.
*   `SetDrawRTF()` and `GetDrawRTF()` (`m_bDrawRTF`): Similar to thumbnails, rendering Rich Text Format (RTF) content can impact performance.

By providing these granular controls, Ditto allows users to balance functionality with performance based on their system resources and usage patterns. The default settings are likely chosen to provide a good balance for most users, but advanced users can optimize for specific needs.


## Security and Privacy Features

Ditto, as a clipboard manager, handles potentially sensitive user data. Its security and privacy implementations are crucial for protecting this information. Based on the source code and search results, several aspects can be highlighted:

### Network Synchronization with Encryption

Ditto supports synchronizing clipboard data across multiple machines, and this communication is designed with security in mind:

*   **Encrypted Connections**: When synchronizing clips over a network, Ditto utilizes encrypted connections to protect the data in transit. This is a significant feature for users who operate in networked environments and need to share clipboard content securely between their devices.
*   **Network Passwords**: The `CGetSetOptions` class in `Options.h` includes `SetNetworkPassword()` and `GetNetworkPassword()` functions, indicating that users can set a password for network synchronization. This adds an authentication layer to prevent unauthorized access to shared clipboard data.

### Data Retention and Control

Users have control over how long their clipboard history is retained, which indirectly contributes to privacy:

*   **Configurable History Size**: As noted in the performance section, users can set a maximum number of entries (`SetMaxEntries()`) and configure the expiration of old entries (`SetExpiredEntries()`). This allows users to limit the amount of sensitive data stored over time.
*   **"Clipboard Viewer Ignore" Format**: The use of `m_cfIgnoreClipboard = ::RegisterClipboardFormat(_T("Clipboard Viewer Ignore"));` in `CP_Main.cpp` suggests that Ditto can be configured to ignore certain clipboard content, potentially allowing other applications to mark sensitive data as not to be saved by clipboard managers.

### Challenges and Considerations

Despite these features, there are known discussions and potential challenges regarding Ditto's security and privacy:

*   **Lack of Database Encryption**: Several discussions [5] [6] indicate that Ditto's SQLite database, where all clipboard history is stored, is *not* encrypted by default. This means that anyone with access to the system and the database file could potentially access the stored clipboard history. This is a significant security concern for highly sensitive data.
*   **"Delete Clip on Paste" Feature**: A requested feature [4] is a "delete clip on paste" option, which would automatically remove sensitive information from the history after it has been pasted. This highlights a user need for more granular control over the lifecycle of sensitive clips.
*   **Increased Surface Area for Exposure**: Clipboard managers, by their nature, increase the amount of data retained and thus the potential surface area for accidental exposure of sensitive information [7]. Users are advised to be mindful of what they copy when using any clipboard manager.

In summary, while Ditto provides encrypted network synchronization and user controls for history retention, the lack of default encryption for its local database is a notable security vulnerability that users should be aware of. The implementation of features like "Clipboard Viewer Ignore" and network passwords demonstrates an awareness of security, but the core data storage could be improved.

## References

1.  [Ditto - Clipboard Manager](https://sabrogden.github.io/Ditto/)
2.  [GitHub - Ditto Clipboard Manager 🧠](https://github.com/ditto-clipboard-manager-windows)
3.  [GitHub - CyberShadow/Ditto: Fork of Ditto Clipboard Manager](https://github.com/CyberShadow/Ditto)
4.  [Feature Request: Security Enhancement - Ditto](https://sourceforge.net/p/ditto-cp/discussion/287510/thread/36dcb0bc/)
5.  [The Ditto app stores the data in an unsecured SQLite ...](https://github.com/sabrogden/Ditto/issues/657)
6.  [Clipboard Managers - Ditto Copyq](https://forums.malwarebytes.com/topic/328676-clipboard-managers-ditto-copyq/)
7.  [Ditto Clipboard Manager: Best Open Source ...](https://windowsforum.com/threads/ditto-clipboard-manager-best-open-source-windows-clipboard-history-tool.383114/)
