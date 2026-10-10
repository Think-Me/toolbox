.PHONY: app run test build clean perms smoke

CONFIG ?= debug

build:
	swift build -c $(CONFIG)

test:
	swift test

app:
	./Scripts/build-app.sh $(CONFIG)

run: app
	open Build/Toolbox.app

# 任务 5 的端到端冒烟：先编译合成器，起监听，再合成 ⌃⌘A。
# 期望输出 register=true 后紧跟 FIRED。没 FIRED 的排查顺序：
#   ① Snipaste/SwitchHosts 是否还开着 ② 发送方有没有辅助功能权限 ③ 才轮到怀疑实现
# Secure Input 开启时（远程桌面/密码框）合成按键会被 HID 层整个丢弃，
# 这时"没等到 FIRED"不代表热键坏了 —— 必须区分报，否则以后会有人
# 对着一个环境问题排查半天代码。
smoke: build
	@swiftc -O -o /tmp/toolbox-secure-input-check Scripts/secure-input-check.swift 2>/dev/null; \
	if ! /tmp/toolbox-secure-input-check 2>/dev/null; then \
		echo "⏭  跳过 smoke：Secure Input 开启中，无法合成按键。"; \
		echo "    要跑这个检查，先退出 RustDesk 等远程桌面工具。"; \
		exit 0; \
	fi; \
	BIN=$$(swift build -c $(CONFIG) --show-bin-path)/Toolbox; \
	swiftc -O -o /tmp/toolbox-smoke-post Scripts/smoke-post-hotkey.swift; \
	rm -f /tmp/toolbox-smoke.log; \
	"$$BIN" --smoke-hotkey 2>/tmp/toolbox-smoke.log & \
	LISTENER=$$!; sleep 2; /tmp/toolbox-smoke-post; sleep 1; \
	cat /tmp/toolbox-smoke.log; kill $$LISTENER 2>/dev/null || true; \
	grep -q "^FIRED$$" /tmp/toolbox-smoke.log \
	  || { echo "❌ smoke 失败：没等到 FIRED，热键回调没触发（或进程根本没跑起来）"; exit 1; }; \
	echo "✅ smoke 通过：热键注册成功且回调真的被触发"

# 打印两项系统权限的真实状态（对照 spec §2.4 / §4.3）
perms:
	@printf 'hosts 可直接写(O_WRONLY 语义): '
	@/bin/test -w /etc/hosts && echo yes || echo "no —— 未 provision，预期如此"
	@printf 'sudo 免密刷 DNS: '
	@sudo -n -k /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 && echo yes || echo "no —— 未装 sudoers，预期如此"

clean:
	rm -rf .build Build

rebuild:
	./Scripts/rebuild.sh $(CONFIG)
