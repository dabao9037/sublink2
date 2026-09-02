from pathlib import Path


INSTALLER = Path(__file__).resolve().parents[1] / "install.sh"


def function_body(name: str, next_name: str) -> str:
    source = INSTALLER.read_text(encoding="utf-8")
    return source.split(f"{name}(){{", maxsplit=1)[1].split(
        f"\n{next_name}(){{", maxsplit=1
    )[0]


def test_application_service_is_enabled_and_health_checked():
    body = function_body("install_app", "change_port")
    assert 'systemd_enable_active "$SERVICE_NAME" "$APP_NAME"' in body
    assert 'atomic_activate "$release_dir"' in body


def test_apache_binding_enables_service_before_and_after_certificate_work():
    body = function_body("write_apache_proxy", "write_nginx_proxy")
    first_enable = body.index("systemd_enable_active apache2.service Apache")
    reload_service = body.index("systemctl reload apache2")
    last_enable = body.rindex("systemd_enable_active apache2.service Apache")
    assert first_enable < reload_service < last_enable


def test_nginx_binding_enables_service_and_does_not_unconditionally_compete():
    body = function_body("write_nginx_proxy", "managed_proxy_kind")
    assert "if port_is_listening 80; then require_active_listener nginx.service Nginx; fi" in body
    assert body.count("systemd_enable_active nginx.service Nginx") == 2


def test_caddy_binding_requires_active_systemd_listener_and_autostart():
    body = function_body("write_caddy_proxy", "ensure_certbot_plugin")
    assert "require_active_listener caddy.service Caddy" in body
    assert "systemd_enable_active caddy.service Caddy" in body


def test_saved_domain_only_repairs_the_detected_managed_proxy():
    body = function_body("ensure_saved_proxy", "show_access")
    assert "case \"$kind\"" in body
    assert "systemd_enable_active caddy.service" in body
    assert "systemd_enable_active apache2.service" in body
    assert "systemd_enable_active nginx.service" in body
    assert "未找到 SubLink2 托管的反向代理配置" in body
