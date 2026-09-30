# Codex custom endpoint installer

Cross-platform installers for configuring a FinnVnoi Codex endpoint in one of two modes:

- `custom-endpoint`: the current behavior, with no ChatGPT/Codex login requirement and the bundled local model catalog.
- `account`: the same endpoint, API key, model, and reasoning prompts, uses the native model catalog, and does not require a login check during installation.

- Windows: `codex_install.ps1` / `codex_uninstall.ps1`
- Linux and macOS, including Bash, Zsh, and Fish: `codex_install.sh` / `codex_uninstall.sh`
- Bundled catalog: `legacy_direct_model_catalog.json`

The default values match the repository owner's setup:

| Setting | Default |
| --- | --- |
| Endpoint | `https://codex.finnvnoi.top/backend-api/codex` |
| Model | `gpt-5.6-sol` |
| Reasoning effort | `xhigh` |
| Provider | `codex` |
| API key variable | `CODEX_API_KEY` |

The API key is never embedded in the scripts or catalog. Pressing Enter at the API key prompt keeps the existing `CODEX_API_KEY`; if it is not already set, an API key must be entered.

Windows saves the variables in the persistent User environment. Linux and macOS automatically load them in every new terminal through the selected shell profile. A running installer process cannot modify the environment of the parent shell that launched it, so the optional `source` command is only needed once for the terminal that was already open during installation.

## English

### Download

```bash
git clone https://github.com/FinnVnoi/newllm.git
cd newllm
```

SSH users can clone with:

```bash
git clone git@github.com:FinnVnoi/newllm.git
cd newllm
```

### Windows

Run PowerShell in the repository directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex_install.ps1
```

The installer first asks for a mode, then prompts for endpoint, API key, model, and reasoning effort. Press Enter to use the defaults shown in the prompt. In `custom-endpoint`, an unknown model also gets a display-name prompt and is added to the installed catalog. In `account`, the installer does not check login; it leaves model discovery to native Codex while routing requests to the configured endpoint.

Select a mode explicitly when scripting:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex_install.ps1 -Mode custom-endpoint
powershell -ExecutionPolicy Bypass -File .\codex_install.ps1 -Mode account
```

Use `-Doctor` to check the active mode, config, and environment:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex_install.ps1 -Doctor
```

Uninstall and restore the original state:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex_uninstall.ps1
```

For unattended installation, set `CODEX_API_KEY` first and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex_install.ps1 -NonInteractive -Mode custom-endpoint
```

Non-interactive installation requires an explicit mode:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex_install.ps1 -NonInteractive -Mode account
```

### Linux

```bash
chmod +x codex_install.sh codex_uninstall.sh
./codex_install.sh
```

The installer asks for the mode and then updates `~/.codex`. It adds a small managed source block to `~/.bashrc`. It uses `~/.zshrc` for Zsh, `~/.config/fish/conf.d/codex-custom-endpoint.fish` for Fish, and `~/.profile` for another POSIX shell. Every terminal opened after installation loads the variables automatically.

To select a mode explicitly:

```bash
./codex_install.sh --mode custom-endpoint
./codex_install.sh --mode account
```

`account` mode does not require a login check during installation. It still asks for and stores the configured endpoint and `CODEX_API_KEY`, but does not enable the local catalog override. The generated provider keeps `requires_openai_auth = true` exactly as shown below, so the Codex runtime may still use native authentication when making requests.

Only if you want to keep using the terminal that was already open during installation, run this once:

```bash
source ~/.codex/codex_custom_endpoint.env
```

Uninstall:

```bash
./codex_uninstall.sh
```

### macOS

```bash
chmod +x codex_install.sh codex_uninstall.sh
./codex_install.sh
```

The default macOS shell is usually Zsh, so the installer adds its managed source block to `~/.zshrc`. When Bash is the active shell, it uses `~/.bash_profile`. Every terminal opened after installation loads the variables automatically.

Only if you want to keep using the terminal that was already open during installation, run this once:

```bash
source ~/.codex/codex_custom_endpoint.env
```

Uninstall:

```bash
./codex_uninstall.sh
```

For unattended Linux or macOS installation:

```bash
export CODEX_API_KEY='your-api-key'
./codex_install.sh --non-interactive --mode custom-endpoint
```

Non-interactive mode requires `--mode account` or `--mode custom-endpoint`.

If Codex reports `invalid_api_key`, run:

```bash
./codex_install.sh --doctor
```

The diagnostic detects the installed mode. It checks the native-catalog provider configuration in `account` mode, checks the local catalog provider in `custom-endpoint` mode, and reports whether the key is loaded without printing it. If all checks pass but the endpoint still reports `invalid_api_key`, close and reopen Codex, then restart the device if needed; rerun the installer only if the issue persists. On Arch Linux with Fish, rerun the latest installer once so it can migrate the managed block from `.profile` to Fish's `conf.d` directory.

### What the installer changes

The installer configures these user-level Codex values:

```toml
model = "gpt-5.6-sol"
model_provider = "codex"
model_reasoning_effort = "xhigh"
model_catalog_json = "/absolute/path/to/.codex/legacy_direct_model_catalog.json"

[model_providers.codex]
name = "CODEX"
base_url = "https://codex.finnvnoi.top/backend-api/codex"
env_key = "CODEX_API_KEY"
wire_api = "responses"
```

`account` mode writes the following provider shape instead. The endpoint, API key variable, model, and reasoning effort are still selected by the installer:

```toml
model = "gpt-5.6-sol"
model_reasoning_effort = "xhigh"
model_provider = "codex"

[model_providers.codex]
name = "openai"
base_url = "https://codex.finnvnoi.top/backend-api/codex"
env_key = "CODEX_API_KEY"
wire_api = "responses"
supports_websockets = false
requires_openai_auth = true
```

This mode does not set `model_catalog_json`, so model discovery uses the native Codex catalog. `requires_openai_auth = true` means an active native Codex/OpenAI login is required. Available models and features still depend on the account and rollout.

It also persists:

- `CODEX_BASE_URL`
- `CODEX_API_KEY`
- `CODEX_MODEL`
- `CODEX_REASONING_EFFORT`

Windows stores them as User environment variables. Linux and macOS store them in `~/.codex/codex_custom_endpoint.env` with file mode `600`, then source that file from the selected shell profile.

The first installation backs up the original config, target catalog, environment data, and related state. Re-running the installer keeps the original backup. Uninstall restores the original files and preserves a safety copy if an installed file was changed afterward.

After installing on Windows, close all running Codex applications and reopen them. After installing on Linux or macOS, restart your device. Restart Codex after uninstalling.

## Tiếng Việt

### Tải repository

```bash
git clone https://github.com/FinnVnoi/newllm.git
cd newllm
```

Nếu đã cấu hình SSH:

```bash
git clone git@github.com:FinnVnoi/newllm.git
cd newllm
```

### Windows

Mở PowerShell tại thư mục repository và chạy:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex_install.ps1
```

Installer sẽ hỏi mode trước, sau đó yêu cầu nhập endpoint, API key, model và reasoning effort. Nhấn Enter để dùng giá trị mặc định hiển thị trên màn hình. `custom-endpoint` giữ hành vi hiện tại; `account` dùng catalog native và không kiểm tra đăng nhập khi cài đặt. Ở `custom-endpoint`, model mới vẫn được hỏi tên hiển thị và thêm vào catalog cài đặt.

Chọn mode rõ ràng:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex_install.ps1 -Mode custom-endpoint
powershell -ExecutionPolicy Bypass -File .\codex_install.ps1 -Mode account
```

Mode `account` không kiểm tra đăng nhập khi cài đặt. Dùng `-Doctor` để kiểm tra mode, config và môi trường. Provider vẫn giữ `requires_openai_auth = true` theo đúng format bên dưới, nên Codex runtime có thể vẫn cần native authentication khi gửi request.

Gỡ cài đặt và khôi phục trạng thái ban đầu:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex_uninstall.ps1
```

Cài đặt không tương tác:

```powershell
$env:CODEX_API_KEY = 'api-key-cua-ban'
powershell -ExecutionPolicy Bypass -File .\codex_install.ps1 -NonInteractive -Mode custom-endpoint
```

Non-interactive bắt buộc phải có `-Mode account` hoặc `-Mode custom-endpoint`.

### Linux

```bash
chmod +x codex_install.sh codex_uninstall.sh
./codex_install.sh
```

Chọn mode rõ ràng bằng `./codex_install.sh --mode custom-endpoint` hoặc `./codex_install.sh --mode account`. Mode `account` vẫn hỏi và lưu endpoint cùng `CODEX_API_KEY`, không bật catalog local và không kiểm tra login khi cài đặt.

Installer cập nhật `~/.codex` và thêm một block có đánh dấu vào `~/.bashrc`. Với Zsh, installer dùng `~/.zshrc`; với Fish, installer dùng `~/.config/fish/conf.d/codex-custom-endpoint.fish`; với shell POSIX khác, installer dùng `~/.profile`. Mọi terminal mở sau khi cài đặt sẽ tự động có các biến này.

Chỉ khi muốn tiếp tục dùng ngay terminal đã mở trong lúc cài, hãy chạy lệnh sau một lần:

```bash
source ~/.codex/codex_custom_endpoint.env
```

Gỡ cài đặt:

```bash
./codex_uninstall.sh
```

### macOS

```bash
chmod +x codex_install.sh codex_uninstall.sh
./codex_install.sh
```

macOS thường dùng Zsh nên installer thêm block vào `~/.zshrc`. Nếu shell hiện tại là Bash, installer dùng `~/.bash_profile`. Mọi terminal mở sau khi cài đặt sẽ tự động có các biến này.

Chỉ khi muốn tiếp tục dùng ngay terminal đã mở trong lúc cài, hãy chạy lệnh sau một lần:

```bash
source ~/.codex/codex_custom_endpoint.env
```

Gỡ cài đặt:

```bash
./codex_uninstall.sh
```

Cài đặt không tương tác trên Linux hoặc macOS:

```bash
export CODEX_API_KEY='api-key-cua-ban'
./codex_install.sh --non-interactive --mode custom-endpoint
```

Non-interactive bắt buộc phải có `--mode account` hoặc `--mode custom-endpoint`.

Nếu Codex báo `invalid_api_key`, hãy chạy:

```bash
./codex_install.sh --doctor
```

Chế độ chẩn đoán tự nhận mode đã cài. Nó kiểm tra provider/catalog native ở mode `account`, kiểm tra provider/catalog local ở mode `custom-endpoint` và chỉ hiển thị số ký tự key, không in key. Nếu mọi kiểm tra đều ổn nhưng vẫn gặp `invalid_api_key`, hãy đóng mở lại Codex rồi khởi động lại thiết bị; chỉ chạy lại installer nếu lỗi vẫn còn. Trên Arch Linux dùng Fish, hãy chạy lại installer mới một lần để managed block được chuyển từ `.profile` sang thư mục `conf.d` của Fish.

### Installer thay đổi những gì

Installer cập nhật cấu hình Codex ở cấp người dùng:

```toml
model = "gpt-5.6-sol"
model_provider = "codex"
model_reasoning_effort = "xhigh"
model_catalog_json = "/duong-dan-tuyet-doi/.codex/legacy_direct_model_catalog.json"

[model_providers.codex]
name = "CODEX"
base_url = "https://codex.finnvnoi.top/backend-api/codex"
env_key = "CODEX_API_KEY"
wire_api = "responses"
```

Mode `account` ghi provider theo dạng sau; endpoint, API key, model và reasoning effort vẫn do installer hỏi giống mode còn lại:

```toml
model = "gpt-5.6-sol"
model_reasoning_effort = "xhigh"
model_provider = "codex"

[model_providers.codex]
name = "openai"
base_url = "https://codex.finnvnoi.top/backend-api/codex"
env_key = "CODEX_API_KEY"
wire_api = "responses"
supports_websockets = false
requires_openai_auth = true
```

Mode này không ghi `model_catalog_json` nên dùng catalog native của Codex. `requires_openai_auth = true` nghĩa là phải đăng nhập Codex/OpenAI native; model và tính năng thực tế vẫn phụ thuộc account và rollout.

Các biến môi trường được lưu:

- `CODEX_BASE_URL`
- `CODEX_API_KEY`
- `CODEX_MODEL`
- `CODEX_REASONING_EFFORT`

Windows lưu chúng bền vững dưới dạng biến môi trường User. Linux và macOS lưu trong `~/.codex/codex_custom_endpoint.env` với quyền file `600`, sau đó tự động nạp file này từ cấu hình shell đã chọn cho mọi terminal mới. Tiến trình installer không thể sửa môi trường của shell cha đang chạy, vì vậy lệnh `source` chỉ cần chạy một lần nếu bạn muốn tiếp tục dùng ngay terminal đã mở từ trước khi cài.

Lần cài đầu tiên sẽ sao lưu config, catalog đích, dữ liệu môi trường và trạng thái liên quan. Chạy lại installer không ghi đè bản sao lưu gốc. Khi uninstall, các file ban đầu được phục hồi; nếu file cài đặt đã bị sửa sau đó, uninstall tạo thêm một bản an toàn trước khi phục hồi.

Sau khi cài đặt trên Windows, hãy đóng tất cả ứng dụng Codex đang chạy rồi mở lại. Sau khi cài đặt trên Linux hoặc macOS, hãy khởi động lại thiết bị. Hãy khởi động lại Codex sau khi gỡ cài đặt.
