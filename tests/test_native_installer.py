import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install.sh"


def source() -> str:
    return INSTALLER.read_text(encoding="utf-8")


def definitions() -> str:
    return source().split('\ncase "$ACTION" in\n', maxsplit=1)[0]


def run_harness(body: str):
    return subprocess.run(
        ["bash"],
        input=f"{definitions()}\n{body}\n",
        text=True,
        capture_output=True,
        check=False,
    )


def test_native_only_runtime_and_old_repo_are_absent():
    runtime_files = [INSTALLER, ROOT / ".github/workflows/test.yml"]
    forbidden = re.compile(r"docker|compose|get\.docker\.com", re.I)
    for path in runtime_files:
        assert not forbidden.search(path.read_text(encoding="utf-8")), path
    assert not (ROOT / "Dockerfile").exists()
    assert not (ROOT / "docker-compose.yml").exists()
    assert "dabao9037/sublink.git" not in source()
    assert "dabao9037/sublink2" in source()


def test_short_command_service_and_autostart_contract():
    text = source()
    assert 'COMMAND_PATH="${SUBLINK2_COMMAND_PATH:-/usr/local/bin/sub}"' in text
    assert 'SERVICE_NAME="sublink2.service"' in text
    assert "ExecStart=${CURRENT_LINK}/venv/bin/uvicorn" in text
    assert "systemctl enable --now" in text
    assert 'WantedBy=multi-user.target' in text
    assert 'User=${SERVICE_USER}' in text
    assert 'NoNewPrivileges=true' in text
    assert 'ProtectSystem=strict' in text


def test_persistent_paths_and_config_keys():
    text = source()
    assert '/var/lib/sublink2' in text
    assert '/etc/sublink2/config.env' in text or 'CONFIG_DIR="${SUBLINK2_CONFIG_DIR:-/etc/sublink2}"' in text
    assert 'DB_PATH=${DATA_DIR}/subscriptions.db' in text
    for key in ("ADMIN_USER", "ADMIN_PASSWORD", "APP_SECRET", "PUBLIC_BASE_URL", "DOMAIN", "DOMAIN_HTTPS"):
        assert f"{key}=${{{key}" in text
    assert "检测到已有安装：数据库、账号、APP_SECRET、端口和域名设置将全部保留" in text


def test_update_builds_before_atomic_switch_and_rolls_back():
    text = source()
    build = text.index('build_release "$release_dir"')
    activate = text.index('atomic_activate "$release_dir"')
    assert build < activate
    assert 'old_target="$(readlink -f "$CURRENT_LINK")"' in text
    assert '正在恢复上一版本' in text
    assert 'mv -Tf "$next_link" "$CURRENT_LINK"' in text
    assert 'health_check' in text


def test_cli_actions_and_menu_are_complete():
    text = source()
    for action in ("install", "update", "port", "credentials", "domain", "status", "logs", "uninstall"):
        assert re.search(rf"\b{action}\b", text)
    for label in ("安装 / 安全更新", "更换端口", "重设后台账号密码", "绑定域名与 HTTPS", "查看状态", "查看日志", "安全卸载"):
        assert label in text


def test_systemd_enable_calls_enabled_and_active_checks():
    result = run_harness(
        r'''
calls=""
systemctl() {
  calls="${calls}$*\n"
  case "$1" in
    enable|is-enabled|is-active) return 0 ;;
  esac
  return 1
}
command_exists() { [ "$1" = systemctl ]; }
systemd_enable_active sublink2.service SubLink2
printf '%b' "$calls"
'''
    )
    assert result.returncode == 0, result.stderr
    assert "enable --now sublink2.service" in result.stdout
    assert "is-enabled --quiet sublink2.service" in result.stdout
    assert "is-active --quiet sublink2.service" in result.stdout


def test_all_managed_proxies_refresh_current_port():
    text = source()
    body = text.split("refresh_proxy_port(){", 1)[1].split("\nensure_saved_proxy(){", 1)[0]
    assert "caddy)" in body
    assert "apache)" in body
    assert "nginx)" in body
    assert body.count('127.0.0.1:${old_port}') >= 3
    assert body.count('127.0.0.1:${new_port}') >= 3
    assert "systemd_enable_active caddy.service" in body
    assert "systemd_enable_active apache2.service" in body
    assert "systemd_enable_active nginx.service" in body
