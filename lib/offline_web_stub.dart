// Не браузер (тесты, Android/iOS): хранилища считаем рабочими,
// сигнала сети нет, localStorage — в памяти.

Future<bool> storageAvailable() async => true;

bool? browserOnline() => null;

void onBrowserOnlineChanged(void Function(bool online)? callback) {}

final Map<String, String> _memory = {};

String? readLocal(String key) => _memory[key];

void writeLocal(String key, String value) => _memory[key] = value;

void setLeaveGuard(bool on) {}

void setBeforeUnloadHook(void Function()? hook) {}

void setBrowserChrome({required String favicon, required String color}) {}
