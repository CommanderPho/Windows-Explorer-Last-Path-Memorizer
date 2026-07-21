# Codrut's Windows Explorer Last Path Memorizer
This app automatically remembers the last path you visited in Explorer and restores it for new windows.

Copyright (c) Codrut Software

## Installation

### Automatic
Open the installer and follow the steps required to install the app.

### Manual
Just copy the executable `ExplorerLastPathMemorizer.exe` in `shell:startup` or create a setting to make the app start automatically with your PC.

### Shortcuts
| Keybind       | Description                                                 |
|:------------:|:------------------------------------------------------------:|
| Ctrl+Shift+T  | Re-open last closed window                                  |
| Ctrl+Shift+R  | Open a popup menu with a list of recently closed windows    |

## Settings
Settings are stored in
```
%appdata%\Codrut Software\Explorer Last Path Memorizer
```

Where you can find `inclusion-rules.txt`
Leave the document empty in order to include all new windows with no path to the rules.

Else type the captions in lowercase (like "this pc" or "home") for which news windows's paths you want navigated.

## Images
<img width="1000" height="605" alt="Recording 2026-07-21 182303" src="https://github.com/user-attachments/assets/21f52ae0-8e89-428b-bb51-4412234c4599" />
