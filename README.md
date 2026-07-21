# Codrut's Windows Explorer Last Path Memorizer
This app automatically remembers the last path you visited in Explorer and restores it for new windows.

Copyright (c) Codrut Software

## Installation

### Automatic
Open the installer and follow the steps required to install the app.

### Manual
Just copy the executable `ExplorerLastPathMemorizer.exe` in `shell:startup` or create a setting to make the app start automatically with your PC.


## Settings
Settings are stored in
```
%appdata%\Codrut Software\Explorer Last Path Memorizer
```

Where you can find `inclusion-rules.txt`
Leave the document empty in order to include all new windows with no path to the rules.

Else type the captions in lowercase (like "this pc" or "home") for which news windows's paths you want navigated.