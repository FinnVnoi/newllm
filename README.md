# Codex custom endpoint installer

Cross-platform installers for configuring Codex CLI and Codex App with a custom Responses API endpoint, model catalog, API key, model, reasoning effort, and optional native quota display.

- Windows: `codex_install.ps1` / `codex_uninstall.ps1`
- Linux and macOS: `codex_install.sh` / `codex_uninstall.sh`
- Bundled model catalog: `legacy_direct_model_catalog.json`
- Quota bridge: `codex_quota_proxy.py`

Default values:

| Setting | Default |
| --- | --- |
| Endpoint | `https://codex.finnvnoi.top/backend-api/codex` |
| Model | `gpt-5.6-sol` |
| Reasoning effort | `xhigh` |
| Show quota | `Yes` |
| Quota endpoint | `https://codex.finnvnoi.top/v1/usage` |
| API key variable | `CODEX_API_KEY` |

The installer never contains a built-in API key. The key is entered interactively or read from an existing `CODEX_API_KEY`.

## English

### Install

```bash
git clone https://github.com/FinnVnoi/newllm.git
cd newllm
```

SSH:

```bash
git clone git@github.com:FinnVnoi/newllm.git
cd newllm
```

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex_install.ps1
```

Linux or macOS:

```bash
chmod +x codex_install.sh codex_uninstall.sh
./codex_install.sh
```

The installer asks for:

1. Model endpoint.
2. API key.
3. Model.
4. Reasoning effort.
5. `Show quota in Codex CLI and Codex App [Y/n]`.
6. Quota endpoint when quota is enabled.

Press Enter to use the displayed defaults. The default quota endpoint is derived from the model endpoint's origin and uses `/v1/usage`.

Non-interactive mode uses all repository defaults and enables quota:

```powershell
$env:CODEX_API_KEY = 'your-api-key'
powershell -ExecutionPolicy Bypass -File .\codex_install.ps1 -NonInteractive
```

```bash
export CODEX_API_KEY='your-api-key'
./codex_install.sh --non-interactive
```

### Native quota display

When `Show quota` is enabled, the installer starts a small local proxy on `127.0.0.1`. It:

- forwards Codex requests to the configured remote endpoint;
- authenticates `/v1/usage` with the same API key;
- converts API-key limits into native `x-codex-*` response headers;
- makes the limits available to both Codex CLI and Codex App;
- never listens on an external network interface.

The API key is not used as the localhost credential. Codex receives a separate random local token, and the proxy replaces it with the real API key only when forwarding to the remote server.

The generated provider also uses `name = "openai"` and `requires_openai_auth = true` for current Codex App and remote-compaction compatibility. Codex App may still ask for the normal Codex/OpenAI sign-in to initialize its account UI, but requests to the custom endpoint use the configured custom API key. WebSocket transport is disabled because the quota bridge uses HTTP/SSE.

For the sample codex-lb response:

- an API-key `lifetime` limit is shown as the primary `usage` limit;
- the upstream `7d` limit is shown as the `weekly` limit;
- `account_pool_usage` is used as a 5h/weekly fallback when detailed upstream limits are hidden;
- a year-9999 lifetime reset is treated as no reset time.

If your existing `[tui]` configuration has no `status_line`, the installer adds:

```toml
[tui]
status_line = ["model-with-reasoning", "five-hour-limit", "weekly-limit"]
```

If you already configured `tui.status_line`, it is preserved. You can add `five-hour-limit` and `weekly-limit` manually if they are not present.

Quota is refreshed every 15 seconds. A temporary quota API failure does not interrupt model requests; the proxy continues forwarding normally and keeps the last valid quota snapshot.

### Startup behavior

The quota proxy starts immediately during installation and automatically after user login:

- Windows: user Startup folder;
- Linux desktop: XDG autostart;
- macOS: user LaunchAgent;
- Linux/macOS shells also run an idempotent startup check from the managed shell profile.

Python 3.8 or newer is required only when quota display is enabled.

### Persistent environment

Windows stores these variables in the persistent User environment:

- `CODEX_BASE_URL`
- `CODEX_API_KEY`
- `CODEX_MODEL`
- `CODEX_REASONING_EFFORT`

When quota is enabled, Windows also stores the proxy endpoint, quota endpoint, localhost token, host, and port in the persistent User environment so Codex App and the Startup launcher work after a new sign-in.

Linux and macOS store the main variables in `~/.codex/codex_custom_endpoint.env` with mode `600`. Bash, Zsh, and other POSIX shells load that file automatically. Fish receives equivalent `set -gx` commands in `~/.config/fish/conf.d/codex-custom-endpoint.fish` with mode `600`, avoiding the POSIX `export` syntax that caused `invalid_api_key` on Fish/Arch Linux.

New terminals load them automatically. To update the terminal that was already open during installation, run once.

Bash/Zsh/POSIX:

```bash
source ~/.codex/codex_custom_endpoint.env
```

Fish:

```fish
source ~/.config/fish/conf.d/codex-custom-endpoint.fish
```

Restart Codex CLI or Codex App after installation.

### Diagnose

Linux/macOS:

```bash
./codex_install.sh --doctor
```

The diagnostic does not print the API key. It checks the persisted environment, shell integration, provider configuration, and quota proxy when enabled.

### Uninstall

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex_uninstall.ps1
```

Linux/macOS:

```bash
./codex_uninstall.sh
```

Uninstall stops the quota proxy, removes its autostart entry, restores the original Codex files and environment, and keeps a safety copy of managed files modified after installation.

## Tiếng Việt

### Cài đặt

```bash
git clone https://github.com/FinnVnoi/newllm.git
cd newllm
```

Nếu đã cấu hình SSH:

```bash
git clone git@github.com:FinnVnoi/newllm.git
cd newllm
```

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex_install.ps1
```

Linux hoặc macOS:

```bash
chmod +x codex_install.sh codex_uninstall.sh
./codex_install.sh
```

Installer sẽ hỏi:

1. Endpoint model.
2. API key.
3. Model.
4. Reasoning effort.
5. `Show quota in Codex CLI and Codex App [Y/n]`.
6. Endpoint quota nếu bật quota.

Nhấn Enter để dùng giá trị mặc định đang hiển thị. Endpoint quota mặc định được suy ra từ origin của endpoint model và dùng đường dẫn `/v1/usage`.

Cài đặt không tương tác sẽ dùng toàn bộ giá trị mặc định và bật quota:

```powershell
$env:CODEX_API_KEY = 'api-key-cua-ban'
powershell -ExecutionPolicy Bypass -File .\codex_install.ps1 -NonInteractive
```

```bash
export CODEX_API_KEY='api-key-cua-ban'
./codex_install.sh --non-interactive
```

### Hiển thị quota trực tiếp

Khi chọn bật `Show quota`, installer chạy một proxy nhỏ chỉ lắng nghe tại `127.0.0.1`. Proxy này:

- chuyển tiếp request của Codex tới endpoint thật;
- gọi `/v1/usage` bằng chính API key đã nhập;
- chuyển quota thành các header `x-codex-*` mà Codex hiểu;
- cung cấp quota cho cả Codex CLI và Codex App;
- không mở cổng ra mạng bên ngoài.

API key thật không được dùng làm mật khẩu localhost. Codex chỉ nhận một token nội bộ ngẫu nhiên; proxy thay token đó bằng API key thật khi chuyển request tới server.

Provider được tạo với `name = "openai"` và `requires_openai_auth = true` để tương thích với Codex App hiện tại và remote compaction. Codex App vẫn có thể yêu cầu đăng nhập Codex/OpenAI thông thường để khởi tạo giao diện tài khoản, nhưng request tới endpoint tùy chỉnh sẽ dùng API key tùy chỉnh đã cấu hình. WebSocket bị tắt vì cầu nối quota dùng HTTP/SSE.

Với JSON codex-lb mẫu:

- quota API key `lifetime` hiện thành giới hạn chính `usage`;
- quota upstream `7d` hiện thành giới hạn `weekly`;
- `account_pool_usage` được dùng làm fallback 5h/weekly khi chi tiết upstream limit bị ẩn;
- thời gian reset năm 9999 được coi là không reset.

Nếu cấu hình `[tui]` hiện tại chưa có `status_line`, installer thêm:

```toml
[tui]
status_line = ["model-with-reasoning", "five-hour-limit", "weekly-limit"]
```

Nếu bạn đã tự cấu hình `tui.status_line`, installer giữ nguyên. Bạn có thể tự thêm `five-hour-limit` và `weekly-limit` nếu chưa có.

Quota được làm mới mỗi 15 giây. Nếu API quota tạm thời lỗi, request model vẫn được chuyển tiếp bình thường và proxy giữ snapshot quota hợp lệ gần nhất.

### Tự khởi động

Proxy quota được chạy ngay trong lúc cài và tự chạy lại sau khi đăng nhập:

- Windows: thư mục Startup của người dùng;
- Linux desktop: XDG autostart;
- macOS: LaunchAgent của người dùng;
- shell Linux/macOS cũng kiểm tra và khởi động proxy theo cách idempotent từ profile do installer quản lý.

Chỉ khi bật quota mới cần Python 3.8 trở lên.

### Biến môi trường bền vững

Windows lưu các biến sau trong User environment:

- `CODEX_BASE_URL`
- `CODEX_API_KEY`
- `CODEX_MODEL`
- `CODEX_REASONING_EFFORT`

Khi bật quota, Windows còn lưu endpoint proxy, endpoint quota, token localhost, host và port trong User environment để Codex App và launcher Startup hoạt động sau lần đăng nhập máy tiếp theo.

Linux và macOS lưu các biến chính trong `~/.codex/codex_custom_endpoint.env` với quyền `600`. Bash, Zsh và shell POSIX khác tự nạp file này. Với Fish, installer ghi các lệnh `set -gx` tương đương vào `~/.config/fish/conf.d/codex-custom-endpoint.fish` với quyền `600`, tránh cú pháp `export` kiểu POSIX từng gây `invalid_api_key` trên Fish/Arch Linux.

Mọi terminal mở sau khi cài sẽ tự nhận biến. Để cập nhật terminal đang mở trong lúc chạy installer, chỉ cần chạy một lần.

Bash/Zsh/POSIX:

```bash
source ~/.codex/codex_custom_endpoint.env
```

Fish:

```fish
source ~/.config/fish/conf.d/codex-custom-endpoint.fish
```

Hãy khởi động lại Codex CLI hoặc Codex App sau khi cài.

### Chẩn đoán

Linux/macOS:

```bash
./codex_install.sh --doctor
```

Chế độ chẩn đoán không in API key. Nó kiểm tra môi trường đã lưu, shell profile, provider config và proxy quota nếu đang bật.

### Gỡ cài đặt

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex_uninstall.ps1
```

Linux/macOS:

```bash
./codex_uninstall.sh
```

Uninstall dừng proxy quota, xóa mục tự khởi động, phục hồi file và biến môi trường ban đầu của Codex, đồng thời giữ bản sao an toàn nếu file do installer quản lý đã bị chỉnh sửa sau khi cài.
