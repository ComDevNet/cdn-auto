# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.5] - 2025-10-18

### Added

- Automated file upload functionality with scheduling options
- AWS S3 bucket region auto-detection
- Enhanced configuration scripts with S3 discovery and validation
- Improved status checking with AWS integration
- Time interval filtering for CSV processing
- Schedule type validation for log selections

### Changed

- Enhanced CSV processing logic with better error handling
- Improved AWS_PROFILE handling across automation scripts
- Streamlined user prompts and interaction flow
- Updated configuration scripts for better error handling
- Unified lolcat piping logic in install and main scripts
- Improved temp file cleanup in test upload functions

### Fixed

- CSV processing error handling and output
- Schedule type validation for non-castle log selections
- Config loading with sudo-aware implementation
- POSIX compliance in status scripts

## [2.0] - 2025-01-28

### Added

- New troubleshooting scripts.
- Added modem connection script.
- Added new log processing algorithm (v5 logs).

### Changed

- Updated tool name to from "rachel-auto" to "cdn-auto"
- Updated interaction to require user input more often.
- Improved performance of the data processing algorithm.
- Updated the user interface to be more user-friendly.
- Removed old unused scripts (Content Request Scripts).

### Fixed

- Fixed a bug where there are 2 requests when connecting to zerotier.

## [1.0] - 2024-07-5

### Added

- Added system update script.
- Added Rachel interface update script.
- Added VPN connection script.
- Added VPN status check script.
- Added interface change script.
- Added system configuration script.
- Added system shutdown script.
- Added system reboot script.
- Added log collection script.
- Added log processing script.
- Added content request file collection script.
- Added VPN disconnection script.
- Added wifi name change script.
- Added wifi password addition script.
- Added data upload script.
