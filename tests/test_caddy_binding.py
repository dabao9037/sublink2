import subprocess
from pathlib import Path


INSTALLER = Path(__file__).resolve().parents[1] / "install.sh"
CADDY_LISTENER_SAMPLE = 'LISTEN 0 8192 *:80 *:* users:(("caddy",pid=429372,fd=3))'


def definitions() -> str:
    return INSTALLER.read_text(encoding="utf-8").split('\ncase "$ACTION" in\n', maxsplit=1)[0]


def run_harness(body: str):
    return subprocess.run(
        ["bash"], input=f"{definitions()}\n{body}\n", text=True, capture_output=True, check=False
    )


def test_installer_reuses_caddy_apache_and_nginx_without_stopping_unknown_listener():
    source = INSTALLER.read_text(encoding="utf-8")
    assert "port_owned_only_by 80 '\"caddy\"'" in source
    assert "port_owned_only_by 80 '\"(apache2|httpd)\"'" in source
    assert "port_owned_only_by 80 '\"nginx\"'" in source
    assert "80 端口由无法安全识别的程序占用；未停止现有服务" in source
    assert "reverse_proxy 127.0.0.1:${SUBLINK_PORT}" in source
    assert "ProxyPass / http://127.0.0.1:${SUBLINK_PORT}/" in source
    assert "proxy_pass http://127.0.0.1:${SUBLINK_PORT}" in source


def test_real_ss_caddy_listener_matches_caddy_branch():
    result = run_harness(
        f'''
listener_summary() {{ printf '%s\\n' '{CADDY_LISTENER_SAMPLE}'; }}
if port_is_listening 80 && port_owned_only_by 80 '"caddy"'; then printf caddy; else exit 1; fi
'''
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout == "caddy"


def test_caddy_admin_off_falls_back_to_systemd_restart():
    result = run_harness(
        r'''
calls=""
caddy() {
  calls="${calls}caddy:$1 "
  case "$1" in validate) return 0;; reload) return 1;; esac
}
systemctl() {
  calls="${calls}systemctl:$1 "
  case "$1" in restart|is-active) return 0;; esac
  return 1
}
caddy_apply || exit 20
printf '%s' "$calls"
'''
    )
    assert result.returncode == 0, result.stderr
    assert "caddy:validate" in result.stdout
    assert "caddy:reload" in result.stdout
    assert "systemctl:restart" in result.stdout
    assert "systemctl:is-active" in result.stdout


def test_working_caddy_admin_api_does_not_restart_service():
    result = run_harness(
        r'''
caddy() { case "$1" in validate|reload) return 0;; esac; }
systemctl() { printf unexpected >&2; return 99; }
caddy_apply
printf safe
'''
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout == "safe"


def test_cloudflare_direct_dns_preflight_is_present():
    source = INSTALLER.read_text(encoding="utf-8")
    assert "Cloudflare 代理（灰云）" in source
    assert "getent ahostsv4" in source
    assert 'grep -Fxq "$public"' in source
