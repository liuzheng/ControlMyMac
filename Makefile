# Installation paths and labels are defined here and exported to scripts through `make env`.
PREFIX        = /usr/local
UI_LABEL      = com.liuzheng.controlmymac.ui
AIRFLOW_LABEL = com.liuzheng.controlmymac.airflow
AIRFLOW_TEMPLATE = Resources/$(AIRFLOW_LABEL).plist
PYTHON_PKG        = python-3.14.7-macos11.pkg
PYTHON_PKG_URL    = https://www.python.org/ftp/python/3.14.7/python-3.14.7-macos11.pkg
PYTHON_PKG_SHA256 = 70c5239ad2d62925d2947e46921d0ddd3d35be3d2f0a2d50db33da507dbcb419
PYTHON_STAGE      = build/python-runtime
APP_DEST          = /Applications/ControlMyMac.app

BUNDLE   = build/ControlMyMac.app
ICON_SRC = Resources/source-icon.webp
ICONSET  = build/AppIcon.iconset
ICNS     = build/AppIcon.icns

.PHONY: all env build bundle python-runtime icon install uninstall clean

all: bundle install

env:
	@printf 'UI_LABEL=%s\n' '$(UI_LABEL)'
	@printf 'AIRFLOW_LABEL=%s\n' '$(AIRFLOW_LABEL)'
	@printf 'AIRFLOW_TEMPLATE=%s\n' '$(AIRFLOW_TEMPLATE)'
	@printf 'APP_DEST=%s\n' '$(APP_DEST)'
	@printf 'BUNDLE=%s\n' '$(BUNDLE)'
	@printf 'PYTHON_PKG=%s\n' '$(PYTHON_PKG)'
	@printf 'PYTHON_STAGE=%s\n' '$(PYTHON_STAGE)'

build:
	@[ "$$(id -u)" -ne 0 ] || { echo "别用 sudo 跑 make：编译会产出 root 所有的产物"; exit 1; }
	swift build -c release

icon: $(ICNS)

$(ICNS): $(ICON_SRC) Tools/make-icon.swift
	@mkdir -p $(ICONSET)
	swift Tools/make-icon.swift $(ICON_SRC) $(ICONSET)
	iconutil -c icns $(ICONSET) -o $(ICNS)

python-runtime: $(PYTHON_PKG)
	bash Tools/prepare-python-runtime.sh "$(PYTHON_PKG)" "$(PYTHON_STAGE)"

$(PYTHON_PKG):
	@set -eu; \
	command -v curl >/dev/null || { echo "需要 curl 才能下载 Python runtime 包" >&2; exit 1; }; \
	command -v shasum >/dev/null || { echo "需要 shasum 才能校验 Python runtime 包" >&2; exit 1; }; \
	tmp="$$(mktemp "$(PYTHON_PKG).XXXXXX")"; \
	trap 'rm -f "$$tmp"' EXIT; \
	echo "正在下载 Python runtime 包：$(PYTHON_PKG)"; \
	curl --fail --location --retry 3 --output "$$tmp" "$(PYTHON_PKG_URL)"; \
	actual="$$(shasum -a 256 "$$tmp" | awk '{print $$1}')"; \
	if [ "$$actual" != "$(PYTHON_PKG_SHA256)" ]; then \
		echo "Python runtime 包校验失败：$$actual" >&2; \
		exit 1; \
	fi; \
	mv "$$tmp" "$@"; \
	trap - EXIT

bundle: build python-runtime $(ICNS)
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources $(BUNDLE)/Contents/Frameworks
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	cp .build/release/ControlMyMac $(BUNDLE)/Contents/MacOS/ControlMyMac
	cp $(ICNS) $(BUNDLE)/Contents/Resources/AppIcon.icns
	cp -R $(PYTHON_STAGE)/Python.framework $(BUNDLE)/Contents/Frameworks/Python.framework
	cp $(PYTHON_STAGE)/PYTHON_LICENSE $(BUNDLE)/Contents/Resources/PYTHON_LICENSE
	cp $(PYTHON_STAGE)/python-runtime.json $(BUNDLE)/Contents/Resources/python-runtime.json
	cp Resources/airflow-supervisor.py $(BUNDLE)/Contents/Resources/airflow-supervisor.py
	chmod 755 $(BUNDLE)/Contents/Resources/airflow-supervisor.py
	cp -R conf $(BUNDLE)/Contents/Resources/conf
	codesign --force --sign - $(BUNDLE)/Contents/Frameworks/Python.framework
	codesign --force --sign - $(BUNDLE)
	@echo "已生成 $(BUNDLE)（含 Python 3.14 runtime）"

install: bundle
	sudo bash scripts/install.sh

uninstall:
	sudo bash scripts/uninstall.sh

clean:
	rm -rf .build build
