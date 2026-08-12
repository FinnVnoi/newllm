# Codex custom endpoint installer

Cross-platform installers for configuring a custom Codex model provider, model catalog, API key, model, and reasoning effort.

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

The installer prompts for endpoint, API key, model, and reasoning effort. Press Enter to use the defaults shown in the prompt.

Uninstall and restore the original state:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex_uninstall.ps1
```

For unattended installation, set `CODEX_API_KEY` first and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex_install.ps1 -NonInteractive
```

### Linux

```bash
chmod +x codex_install.sh codex_uninstall.sh
./codex_install.sh
```

The installer updates `~/.codex` and adds a small managed source block to `~/.bashrc`. It uses `~/.zshrc` for Zsh, `~/.config/fish/conf.d/codex-custom-endpoint.fish` for Fish, and `~/.profile` for another POSIX shell. Every terminal opened after installation loads the variables automatically.

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
./codex_install.sh --non-interactive
```

If Codex reports `invalid_api_key`, run:

```bash
./codex_install.sh --doctor
```

The diagnostic only reports whether the key is loaded, its character count, whether the current key matches the saved key, and whether the provider config is present. It never prints the key. On Arch Linux with Fish, rerun the latest installer once so it can migrate the managed block from `.profile` to Fish's `conf.d` directory.

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

It also persists:

- `CODEX_BASE_URL`
- `CODEX_API_KEY`
- `CODEX_MODEL`
- `CODEX_REASONING_EFFORT`

Windows stores them as User environment variables. Linux and macOS store them in `~/.codex/codex_custom_endpoint.env` with file mode `600`, then source that file from the selected shell profile.

The first installation backs up the original config, target catalog, environment data, and related state. Re-running the installer keeps the original backup. Uninstall restores the original files and preserves a safety copy if an installed file was changed afterward.

Restart Codex after installing or uninstalling.

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

Installer sẽ yêu cầu nhập endpoint, API key, model và reasoning effort. Nhấn Enter để dùng giá trị mặc định hiển thị trên màn hình.

Gỡ cài đặt và khôi phục trạng thái ban đầu:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex_uninstall.ps1
```

Cài đặt không tương tác:

```powershell
$env:CODEX_API_KEY = 'api-key-cua-ban'
powershell -ExecutionPolicy Bypass -File .\codex_install.ps1 -NonInteractive
```

### Linux

```bash
chmod +x codex_install.sh codex_uninstall.sh
./codex_install.sh
```

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
./codex_install.sh --non-interactive
```

Nếu Codex báo `invalid_api_key`, hãy chạy:

```bash
./codex_install.sh --doctor
```

Chế độ chẩn đoán chỉ cho biết key đã được nạp hay chưa, số ký tự của key, key hiện tại có khớp key đã lưu không và provider config có tồn tại không. Nó không bao giờ in giá trị key. Trên Arch Linux dùng Fish, hãy chạy lại installer mới một lần để managed block được chuyển từ `.profile` sang thư mục `conf.d` của Fish.

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

Các biến môi trường được lưu:

- `CODEX_BASE_URL`
- `CODEX_API_KEY`
- `CODEX_MODEL`
- `CODEX_REASONING_EFFORT`

Windows lưu chúng bền vững dưới dạng biến môi trường User. Linux và macOS lưu trong `~/.codex/codex_custom_endpoint.env` với quyền file `600`, sau đó tự động nạp file này từ cấu hình shell đã chọn cho mọi terminal mới. Tiến trình installer không thể sửa môi trường của shell cha đang chạy, vì vậy lệnh `source` chỉ cần chạy một lần nếu bạn muốn tiếp tục dùng ngay terminal đã mở từ trước khi cài.

Lần cài đầu tiên sẽ sao lưu config, catalog đích, dữ liệu môi trường và trạng thái liên quan. Chạy lại installer không ghi đè bản sao lưu gốc. Khi uninstall, các file ban đầu được phục hồi; nếu file cài đặt đã bị sửa sau đó, uninstall tạo thêm một bản an toàn trước khi phục hồi.

Hãy khởi động lại Codex sau khi cài đặt hoặc gỡ cài đặt.
