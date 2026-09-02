import os
import pwd
import re
import shlex
import stat
import subprocess
from pathlib import Path

import pytest


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
    assert 'StartLimitIntervalSec=30' in text
    assert 'StartLimitBurst=3' in text


def test_persistent_paths_and_config_keys():
    text = source()
    assert '/var/lib/sublink2' in text
    assert '/etc/sublink2/config.env' in text or 'CONFIG_DIR="${SUBLINK2_CONFIG_DIR:-/etc/sublink2}"' in text
    assert 'DB_PATH=${DATA_DIR}/subscriptions.db' in text
    for key in ("ADMIN_USER", "ADMIN_PASSWORD", "APP_SECRET", "PUBLIC_BASE_URL", "DOMAIN", "DOMAIN_HTTPS"):
        assert f"{key}=${{{key}" in text
    assert "检测到已有安装：数据库、账号、APP_SECRET、端口和域名设置将全部保留" in text


def test_write_config_does_not_leak_private_umask(tmp_path):
    config = tmp_path / "config.env"
    result = run_harness(
        rf'''
CONFIG_FILE={shlex.quote(str(config))}
SERVICE_USER=nobody
DATA_DIR={shlex.quote(str(tmp_path / "data"))}
SUBLINK_HOST=127.0.0.1
SUBLINK_PORT=8096
ADMIN_USER=admin
ADMIN_PASSWORD=test-password
APP_SECRET=test-secret
PUBLIC_BASE_URL=
DOMAIN=
DOMAIN_HTTPS=0
umask 0022
before="$(umask)"
write_config
printf 'before=%s after=%s\n' "$before" "$(umask)"
'''
    )
    assert result.returncode == 0, result.stderr
    assert "before=0022 after=0022" in result.stdout
    assert stat.S_IMODE(config.stat().st_mode) == 0o640


def test_release_permissions_are_normalized_without_making_source_executable(tmp_path):
    release = tmp_path / "release"
    (release / "venv/bin").mkdir(parents=True, mode=0o700)
    python = release / "venv/bin/python"
    python.write_text("#!/bin/sh\nprintf ok\\n", encoding="utf-8")
    python.chmod(0o700)
    uvicorn = release / "venv/bin/uvicorn"
    uvicorn.write_text("#!/bin/sh\nprintf uvicorn\\n", encoding="utf-8")
    uvicorn.chmod(0o700)
    source_file = release / "app/main.py"
    source_file.parent.mkdir(mode=0o700)
    source_file.write_text("value = 1\n", encoding="utf-8")
    source_file.chmod(0o600)

    result = run_harness(
        f"chown() {{ :; }}\nnormalize_release_permissions {str(release)!r}"
    )
    assert result.returncode == 0, result.stderr
    assert stat.S_IMODE(release.stat().st_mode) == 0o755
    assert stat.S_IMODE((release / "venv").stat().st_mode) == 0o755
    assert stat.S_IMODE((release / "venv/bin").stat().st_mode) == 0o755
    assert stat.S_IMODE(python.stat().st_mode) == 0o755
    assert stat.S_IMODE(uvicorn.stat().st_mode) == 0o755
    assert stat.S_IMODE(source_file.stat().st_mode) == 0o644
    assert not (source_file.stat().st_mode & 0o111)
    assert not (source_file.stat().st_mode & 0o022)


@pytest.mark.skipif(os.geteuid() != 0, reason="requires root to drop to nobody")
def test_low_privilege_user_can_traverse_and_execute_normalized_release(tmp_path):
    nobody = pwd.getpwnam("nobody")
    release = tmp_path / "release"
    (release / "venv/bin").mkdir(parents=True, mode=0o700)
    python = release / "venv/bin/python"
    python.write_text("#!/bin/sh\nprintf 'service-user-ok\\n'\n", encoding="utf-8")
    python.chmod(0o700)
    # pytest's private tmp parents are intentionally not traversable; normalize the
    # complete synthetic install chain just as /opt/sublink2 is normalized.
    for parent in (tmp_path, release, release / "venv", release / "venv/bin"):
        parent.chmod(0o700)

    with pytest.raises(PermissionError):
        subprocess.run(
            [str(python)], capture_output=True, text=True, check=False,
            user=nobody.pw_uid, group=nobody.pw_gid,
        )

    result = run_harness(f"normalize_release_permissions {str(release)!r}")
    assert result.returncode == 0, result.stderr
    for parent in tmp_path.parents:
        if parent == Path("/tmp"):
            break
        parent.chmod(0o755)
    tmp_path.chmod(0o755)
    after = subprocess.run(
        [str(python)], capture_output=True, text=True, check=False,
        user=nobody.pw_uid, group=nobody.pw_gid,
    )
    assert after.returncode == 0, after.stderr
    assert after.stdout.strip() == "service-user-ok"


def test_preflight_executes_python_and_uvicorn_as_service_user():
    text = source()
    body = text.split("verify_release_for_service_user(){", 1)[1].split(
        "\ninstall_command(){", 1
    )[0]
    assert 'run_as_service_user "$release_dir/venv/bin/python" -c' in body
    assert 'run_as_service_user "$release_dir/venv/bin/uvicorn" --version' in body
    assert 'verify_release_for_service_user "$release_dir"' in text
    install_app = text.split("install_app(){", 1)[1].split("\nchange_port(){", 1)[0]
    assert install_app.index('verify_release_for_service_user "$release_dir"') < install_app.index(
        'atomic_activate "$release_dir"'
    )


def test_health_check_exits_early_on_systemd_exec_failure():
    text = source()
    body = text.split("health_check(){", 1)[1].split("\nfetch_source(){", 1)[0]
    assert "systemctl is-failed --quiet" in body
    assert "ExecMainStatus" in body
    assert "203" in body


def test_failed_first_install_is_stopped_and_broken_current_is_not_a_rollback_target():
    text = source()
    body = text.split("install_app(){", 1)[1].split("\nchange_port(){", 1)[0]
    assert 'systemctl is-failed --quiet "$SERVICE_NAME"' in body
    assert 'systemctl stop "$SERVICE_NAME"' in body
    assert 'systemctl reset-failed "$SERVICE_NAME"' in body
    atomic = text.split("atomic_activate(){", 1)[1].split("\nprune_releases(){", 1)[0]
    assert '[ -d "$old_target" ] || old_target=""' in atomic
    assert 'systemctl disable --now "$SERVICE_NAME"' in atomic
    assert 'rm -f "$CURRENT_LINK"' in atomic


def test_update_builds_before_atomic_switch_and_rolls_back():
    text = source()
    build = text.index('build_release "$release_dir"')
    activate = text.index('atomic_activate "$release_dir"')
    assert build < activate
    assert 'old_target="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"' in text
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
