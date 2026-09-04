#!/bin/sh
# Regenerate AnkiClone.xcodeproj from project.yml.
#
# XcodeGen 2.45 always writes objectVersion 77, which Xcode 15.4 refuses to open
# ("future Xcode project file format"). The project uses no format-77 features,
# so the header is rewritten to 60 afterwards, and the compatibilityVersion
# XcodeGen no longer emits is put back — without it older Xcode cannot open the
# project at all.
set -e
cd "$(dirname "$0")"
xcodegen generate
sed -i '' -e 's/objectVersion = 77;/objectVersion = 60;/' \
          -e '/preferredProjectObjectVersion = 77;/d' \
          -e 's|^\(	*\)buildConfigurationList = \(.*\) /\* Build configuration list for PBXProject "AnkiClone" \*/;|\1buildConfigurationList = \2 /* Build configuration list for PBXProject "AnkiClone" */;\
\1compatibilityVersion = "Xcode 14.0";|' \
          AnkiClone.xcodeproj/project.pbxproj
echo "Generated AnkiClone.xcodeproj"
