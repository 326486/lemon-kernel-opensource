#!/system/bin/sh
P=/data/lemonbrain/work/panel
SYS=$P/sysroot/data/data/com.termux/files/usr
export PREFIX=/data/data/com.termux/files/usr
export PATH=$PREFIX/bin:$PATH
export LD_LIBRARY_PATH=$SYS/lib:$PREFIX/lib
AAPT2=$SYS/bin/aapt2
APKSIGNER_JAR=$SYS/share/java/apksigner.jar
AJ=$P/android.jar
cd $P/apk || exit 1
echo "aapt2=$("$AAPT2" version 2>&1|head -1)"
echo '=== 1 compile ==='; "$AAPT2" compile --dir res -o res.zip || exit 1
echo '=== 2 link ==='; "$AAPT2" link -o base.apk -I "$AJ" --manifest AndroidManifest.xml -R res.zip --auto-add-overlay || exit 1
echo '=== 3 javac ==='; mkdir -p classes; javac -source 1.8 -target 1.8 -bootclasspath "$AJ" -d classes src/com/lemon/panel/MainActivity.java || exit 1
echo '=== 4 d8 ==='; mkdir -p dexout; d8 --release --lib "$AJ" --output dexout $(find classes -name '*.class') || exit 1
echo '=== 5 dex入包 ==='; $PREFIX/bin/python3 -c "import zipfile;z=zipfile.ZipFile('base.apk','a');z.write('dexout/classes.dex','classes.dex');z.close()" || exit 1
cp base.apk aligned.apk
echo '=== 6 keystore ==='; [ -f panel.keystore ] || keytool -genkeypair -keystore panel.keystore -alias panel -keyalg RSA -keysize 2048 -validity 10000 -storepass <REDACTED_CREDENTIAL> -keypass <REDACTED_CREDENTIAL> -dname "CN=LemonPanel,OU=Lemon,O=Lemon,L=Changsha,ST=Hunan,C=CN" 2>&1 | tail -1
echo '=== 7 sign ==='; java -jar "$APKSIGNER_JAR" sign --ks panel.keystore --ks-pass pass:<REDACTED_CREDENTIAL> --key-pass pass:<REDACTED_CREDENTIAL> --out lemon-panel.apk aligned.apk || exit 1
java -jar "$APKSIGNER_JAR" verify lemon-panel.apk && echo SIGN_VERIFIED
ls -l lemon-panel.apk
echo BUILD_DONE
