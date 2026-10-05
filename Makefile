.PHONY: gen build run test shot dmg clean

# project.yml is the source of truth; Neat.xcodeproj is generated and gitignored.
gen:
	xcodegen generate

build: gen
	xcodebuild -project Neat.xcodeproj -scheme Neat -configuration Debug build

# Fast path: the modules test without Xcode at all.
test:
	cd Packages/NeatKit && swift test

run: build
	open "$$(xcodebuild -project Neat.xcodeproj -scheme Neat -configuration Debug -showBuildSettings \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {d=$$2} / FULL_PRODUCT_NAME/ {n=$$2} END {print d"/"n}')"

# Screenshot the running app. See Scripts/shot.sh for why this is not XcodeBuildMCP.
shot:
	@Scripts/shot.sh $(if $(OUT),$(OUT),shot.png)

# Styled installer DMG. See Scripts/build-dmg.sh for the macOS 26 traps.
dmg: gen
	Scripts/build-dmg.sh

clean:
	rm -rf Neat.xcodeproj build DerivedData Packages/NeatKit/.build .dmgvenv release
