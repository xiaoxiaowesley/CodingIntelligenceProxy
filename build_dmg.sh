# 1. 用 Release 模式构建
xcodebuild build \
  -project CodingIntelligenceProxy.xcodeproj \
  -scheme CodingIntelligenceProxy \
  -configuration Release \
  -derivedDataPath build

# 2. 构建产物在这里
# build/Build/Products/Release/CodingIntelligenceProxy.app

# 3. 打包成 DMG
mkdir -p build/dmg-content
cp -R "build/Build/Products/Release/CodingIntelligenceProxy.app" build/dmg-content/
ln -s /Applications build/dmg-content/Applications

hdiutil create \
  -volname "CodingIntelligenceProxy" \
  -srcfolder build/dmg-content \
  -ov -format UDZO \
  CodingIntelligenceProxy.dmg