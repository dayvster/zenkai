#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <oleauto.h>
#include <shlobj.h>

using StartAppCallback = void (*)(const wchar_t *, const wchar_t *, const wchar_t *, const wchar_t *, void *);
using StartAppFilter = bool (*)(const wchar_t *, void *);

static HRESULT callMember(IDispatch *object, const wchar_t *name, WORD flags, VARIANT *arguments, UINT argumentCount, VARIANT *result) {
    LPOLESTR member = const_cast<LPOLESTR>(name);
    DISPID id = 0;
    HRESULT hr = object->GetIDsOfNames(IID_NULL, &member, 1, LOCALE_USER_DEFAULT, &id);
    if (FAILED(hr)) return hr;
    DISPPARAMS params{arguments, nullptr, argumentCount, 0};
    return object->Invoke(id, IID_NULL, LOCALE_USER_DEFAULT, flags, &params, result, nullptr, nullptr);
}

static HRESULT getDispatch(IDispatch *object, const wchar_t *name, WORD flags, VARIANT *arguments, UINT argumentCount, IDispatch **result) {
    VARIANT value;
    VariantInit(&value);
    HRESULT hr = callMember(object, name, flags, arguments, argumentCount, &value);
    if (SUCCEEDED(hr)) {
        VARIANT converted;
        VariantInit(&converted);
        hr = VariantChangeType(&converted, &value, 0, VT_DISPATCH);
        if (SUCCEEDED(hr)) {
            *result = converted.pdispVal;
            converted.vt = VT_EMPTY;
        }
        VariantClear(&converted);
    }
    VariantClear(&value);
    return hr;
}

static HRESULT getString(IDispatch *object, const wchar_t *name, WORD flags, VARIANT *arguments, UINT argumentCount, BSTR *result) {
    VARIANT value;
    VariantInit(&value);
    HRESULT hr = callMember(object, name, flags, arguments, argumentCount, &value);
    if (SUCCEEDED(hr)) {
        VARIANT converted;
        VariantInit(&converted);
        hr = VariantChangeType(&converted, &value, 0, VT_BSTR);
        if (SUCCEEDED(hr)) {
            *result = SysAllocStringLen(converted.bstrVal, SysStringLen(converted.bstrVal));
            if (!*result) hr = E_OUTOFMEMORY;
        }
        VariantClear(&converted);
    }
    VariantClear(&value);
    return hr;
}

static void release(IDispatch *value) {
    if (value) value->Release();
}

extern "C" int zenkai_enumerate_start_apps(StartAppFilter filter, StartAppCallback callback, void *context) {
    if (!callback) return E_INVALIDARG;

    const HRESULT initResult = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    const bool uninitialize = SUCCEEDED(initResult);
    if (FAILED(initResult) && initResult != RPC_E_CHANGED_MODE) return initResult;

    HRESULT hr = S_OK;
    CLSID shellClass{};
    IDispatch *shell = nullptr;
    IDispatch *folder = nullptr;
    IDispatch *items = nullptr;

    hr = CLSIDFromProgID(L"Shell.Application", &shellClass);
    if (SUCCEEDED(hr)) hr = CoCreateInstance(shellClass, nullptr, CLSCTX_INPROC_SERVER | CLSCTX_LOCAL_SERVER, IID_IDispatch, reinterpret_cast<void **>(&shell));

    VARIANT folderArg;
    VariantInit(&folderArg);
    folderArg.vt = VT_BSTR;
    folderArg.bstrVal = SysAllocString(L"shell:AppsFolder");
    if (SUCCEEDED(hr) && !folderArg.bstrVal) hr = E_OUTOFMEMORY;
    if (SUCCEEDED(hr)) hr = getDispatch(shell, L"Namespace", DISPATCH_METHOD, &folderArg, 1, &folder);
    VariantClear(&folderArg);
    if (SUCCEEDED(hr)) hr = getDispatch(folder, L"Items", DISPATCH_METHOD, nullptr, 0, &items);

    VARIANT countValue;
    VariantInit(&countValue);
    if (SUCCEEDED(hr)) hr = callMember(items, L"Count", DISPATCH_PROPERTYGET, nullptr, 0, &countValue);
    if (SUCCEEDED(hr)) hr = VariantChangeType(&countValue, &countValue, 0, VT_I4);

    const LONG count = SUCCEEDED(hr) ? countValue.lVal : 0;
    for (LONG index = 0; SUCCEEDED(hr) && index < count; ++index) {
        VARIANT itemArg;
        VariantInit(&itemArg);
        itemArg.vt = VT_I4;
        itemArg.lVal = index;
        IDispatch *item = nullptr;
        hr = getDispatch(items, L"Item", DISPATCH_METHOD, &itemArg, 1, &item);
        VariantClear(&itemArg);
        if (FAILED(hr)) break;

        BSTR name = nullptr;
        BSTR path = nullptr;
        BSTR appId = nullptr;
        BSTR target = nullptr;
        BSTR packagePath = nullptr;
        if (SUCCEEDED(getString(item, L"Name", DISPATCH_PROPERTYGET, nullptr, 0, &name)) && name && SysStringLen(name) > 0 && (!filter || filter(name, context))) {
            VARIANT key;
            VariantInit(&key);
            key.vt = VT_BSTR;
            key.bstrVal = SysAllocString(L"System.AppUserModel.ID");
            if (key.bstrVal) getString(item, L"ExtendedProperty", DISPATCH_METHOD, &key, 1, &appId);
            VariantClear(&key);
            if (!appId || SysStringLen(appId) == 0) {
                getString(item, L"Path", DISPATCH_PROPERTYGET, nullptr, 0, &path);
                if (path) {
                    SysFreeString(appId);
                    appId = SysAllocStringLen(path, SysStringLen(path));
                }
            }

            key.vt = VT_BSTR;
            key.bstrVal = SysAllocString(L"System.Link.TargetParsingPath");
            if (key.bstrVal) getString(item, L"ExtendedProperty", DISPATCH_METHOD, &key, 1, &target);
            VariantClear(&key);

            if (!target || SysStringLen(target) == 0) {
                key.vt = VT_BSTR;
                key.bstrVal = SysAllocString(L"System.AppUserModel.PackageInstallPath");
                if (key.bstrVal) getString(item, L"ExtendedProperty", DISPATCH_METHOD, &key, 1, &packagePath);
                VariantClear(&key);
            }

            callback(name, appId ? appId : L"", target ? target : L"", packagePath ? packagePath : L"", context);
        }

        SysFreeString(name);
        SysFreeString(path);
        SysFreeString(appId);
        SysFreeString(target);
        SysFreeString(packagePath);
        release(item);
    }

    VariantClear(&countValue);
    release(items);
    release(folder);
    release(shell);
    if (uninitialize) CoUninitialize();
    return hr;
}
