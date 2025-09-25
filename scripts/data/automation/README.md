# Log Processor Automation Module

## 1. Overview

This module automates the entire log processing pipeline, from data collection to uploading. It is designed to run as a reliable, unattended background service on a Linux server. 
The core of the automation is built using **systemd**, Linux's native service manager. This was chosen over other methods like `cron` because it offers superior logging via the system journal, better service dependency management, and more flexible timer configurations.

---

## 2. Key Features ✨

-   **Scheduled Execution**: Automatically runs the data pipeline on a configurable schedule using a dedicated `systemd` timer.
-   **Intelligent Offline Queueing**: If the internet is unavailable, processed files are automatically placed in an `00_DATA/00_UPLOAD_QUEUE` directory. The system flushes this queue by uploading all pending files the next time it runs with an active internet connection.
-   **Advanced Interactive Menu**: A user-friendly menu (enhanced with `whiptail` if available) for installing, checking status, and configuring the automation.
-   **Dynamic & Validated Configuration**: The configuration script dynamically discovers available S3 buckets and subfolders. Before saving, it performs a **live upload test** to validate that the chosen settings and AWS credentials are correct.
-   **Comprehensive Status Dashboard**: The status script provides a full health check, including timer status, queue contents, network connectivity, and AWS identity verification.
-   **Dual Logging**: All output is simultaneously logged to both the systemd journal (viewable with `journalctl`) and a persistent file at `/var/log/v5_log_processor/automation.log` for robust troubleshooting.
-   **Automatic AWS Region Detection**: The upload scripts automatically detect the correct AWS region for the target S3 bucket, eliminating the need for manual configuration.

---

## 3. How It Works ⚙️

The automation follows a clear, multi-stage workflow triggered by a system timer.

1.  **Timer Triggers**: At the scheduled time, the `v5-log-processor.timer` unit tells `systemd` to start the service. The schedule is managed via a robust override file in `/etc/systemd/system/v5-log-processor.timer.d/`.
2.  **Service Runs**: The `v5-log-processor.service` unit executes the main wrapper script located at `/usr/local/bin/run_v5_log_processor.sh`.
3.  **Pipeline Initiated**: The wrapper script is responsible for setting up the environment. It navigates to the project directory and executes the main pipeline script, `scripts/data/automation/runner.sh`. It also uses the `tee` command to pipe all output to both the journal and the log file.
4.  **Configuration Loaded**: The `runner.sh` script sources its settings from `config/automation.conf`, loading the correct Server Version, S3 Bucket, etc.
5.  **The Data Workflow (executed by `runner.sh`)**:
    -   **Collect**: The script collects raw server logs based on the `SERVER_VERSION` setting.
    -   **Process**: The collected logs are cleaned and transformed into a `summary.csv` by the appropriate Python processor (`log.py`, `logv2.py`, or `castle.py`), which is selected based on the `SERVER_VERSION` and `PYTHON_SCRIPT` variables.
    -   **Filter & Finalize**: The `summary.csv` is further processed by `process_csv.py` to generate the final, month-specific CSV file.
    -   **Upload or Queue**: The script checks for internet connectivity.
        -   If **online**, it first runs the `flush_queue.sh` logic to upload any previously queued files, then uploads the newly generated file.
        -   If **offline**, it copies the new file to the `00_DATA/00_UPLOAD_QUEUE` directory to be uploaded later.

---

## 4. Usage and Management

To manage the automation, navigate to the project root and run the menu script.

```bash
./main.sh


---

## ⚙️ Automation

This project includes a powerful automation module for scheduling the entire log processing pipeline. It can be installed as a systemd service to run automatically, even when no user is logged in.

**[For full details, see the Automation Module Documentation](./scripts/data/automation/README.md)**