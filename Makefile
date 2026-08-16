.PHONY: setup run check build

setup:
	./scripts/bootstrap.sh

run:
	cd app && flutter run -d macos

check:
	./scripts/verify.sh

build:
	./scripts/build_macos.sh release
