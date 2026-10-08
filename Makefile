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
smoke: build
	@BIN=$$(swift build -c $(CONFIG) --show-bin-path)/Toolbox; \
	swiftc -O -o /tmp/toolbox-smoke-post Scripts/smoke-post-hotkey.swift; \
	rm -f /tmp/toolbox-smoke.log; \
	"$$BIN" --smoke-hotkey 2>/tmp/toolbox-smoke.log & \
	LISTENER=$$!; sleep 2; /tmp/toolbox-smoke-post; sleep 1; \
	cat /tmp/toolbox-smoke.log; kill $$LISTENER 2>/dev/null || true

# 打印两项系统权限的真实状态（对照 spec §2.4 / §4.3）
perms:
	@printf 'hosts 可直接写(O_WRONLY 语义): '
	@/bin/test -w /etc/hosts && echo yes || echo "no —— 未 provision，预期如此"
	@printf 'sudo 免密刷 DNS: '
	@sudo -n -k /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 && echo yes || echo "no —— 未装 sudoers，预期如此"

clean:
	rm -rf .build Build
