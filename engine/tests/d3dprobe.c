/* d3dprobe: creates a Direct3D 11 and a Direct3D 12 device and reports what answered.
 * Build: x86_64-w64-mingw32-gcc -O2 -o d3dprobe.exe d3dprobe.c -ld3d11 -ldxgi -ld3d12 -lole32 -luuid
 * Exit code: 0 when every requested API produced a device. */
#define COBJMACROS
#define INITGUID
#define WIDL_C_INLINE_WRAPPERS  /* GetAdapterLuid returns a struct */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <d3d11.h>
#include <d3d12.h>
#include <dxgi1_4.h>

static void module_path(const char *name)
{
    char path[MAX_PATH] = "";
    HMODULE m = GetModuleHandleA(name);
    if (m) GetModuleFileNameA(m, path, sizeof(path));
    printf("  %-12s %s\n", name, m ? path : "(not loaded)");
}

static int probe_d3d11(void)
{
    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    D3D_FEATURE_LEVEL fl = 0;
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                   D3D11_SDK_VERSION, &dev, &fl, &ctx);
    printf("d3d11: hr=%#lx feature_level=%#x\n", (unsigned long)hr, (unsigned)fl);
    if (FAILED(hr)) return 1;
    IDXGIDevice *dxgi_dev;
    if (SUCCEEDED(ID3D11Device_QueryInterface(dev, &IID_IDXGIDevice, (void **)&dxgi_dev)))
    {
        IDXGIAdapter *ad;
        DXGI_ADAPTER_DESC desc;
        if (SUCCEEDED(IDXGIDevice_GetAdapter(dxgi_dev, &ad)) && SUCCEEDED(IDXGIAdapter_GetDesc(ad, &desc)))
            printf("  adapter: %ls vendor=%04x device=%04x vram=%llu MB\n", desc.Description,
                   desc.VendorId, desc.DeviceId, (unsigned long long)desc.DedicatedVideoMemory >> 20);
        IDXGIDevice_Release(dxgi_dev);
    }
    module_path("d3d11.dll");
    module_path("dxgi.dll");
    module_path("winemetal.dll");
    ID3D11DeviceContext_Release(ctx);
    ID3D11Device_Release(dev);
    return 0;
}

/* What the D3D12 device's adapter reports as its video memory budget, and how long a call
 * takes: Unreal Engine 5 polls this every frame and waits while usage is over budget. */
static void video_memory(ID3D12Device *dev)
{
    LUID luid = ID3D12Device_GetAdapterLuid(dev);
    IDXGIFactory4 *factory;
    IDXGIAdapter3 *ad;
    if (FAILED(CreateDXGIFactory1(&IID_IDXGIFactory4, (void **)&factory))) { printf("  video memory: no IDXGIFactory4\n"); return; }
    if (FAILED(IDXGIFactory4_EnumAdapterByLuid(factory, luid, &IID_IDXGIAdapter3, (void **)&ad)))
    {
        printf("  video memory: no IDXGIAdapter3 for the device's adapter\n");
        IDXGIFactory4_Release(factory);
        return;
    }
    for (int group = 0; group < 2; group++)
    {
        DXGI_QUERY_VIDEO_MEMORY_INFO info = {0};
        HRESULT hr = IDXGIAdapter3_QueryVideoMemoryInfo(ad, 0, group ? DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL
                                                                     : DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &info);
        printf("  video memory %-9s hr=%#lx budget=%llu MB usage=%llu MB available_for_reservation=%llu MB\n",
               group ? "non-local" : "local", (unsigned long)hr, (unsigned long long)info.Budget >> 20,
               (unsigned long long)info.CurrentUsage >> 20, (unsigned long long)info.AvailableForReservation >> 20);
    }
    LARGE_INTEGER freq, t0, t1;
    DXGI_QUERY_VIDEO_MEMORY_INFO info;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&t0);
    for (int i = 0; i < 1000; i++) IDXGIAdapter3_QueryVideoMemoryInfo(ad, 0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &info);
    QueryPerformanceCounter(&t1);
    printf("  video memory: 1000 queries took %.1f ms\n", (t1.QuadPart - t0.QuadPart) * 1000.0 / freq.QuadPart);
    IDXGIAdapter3_Release(ad);
    IDXGIFactory4_Release(factory);
}

static int probe_d3d12(void)
{
    ID3D12Device *dev = NULL;
    HRESULT hr = D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev);
    printf("d3d12: hr=%#lx\n", (unsigned long)hr);
    if (FAILED(hr)) return 1;
    D3D12_FEATURE_DATA_D3D12_OPTIONS5 o5 = {0};
    if (SUCCEEDED(ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_D3D12_OPTIONS5, &o5, sizeof(o5))))
        printf("  raytracing tier=%d\n", o5.RaytracingTier);
    video_memory(dev);
    module_path("d3d12.dll");
    module_path("dxgi.dll");
    ID3D12Device_Release(dev);
    return 0;
}

int main(int argc, char **argv)
{
    int want11 = 1, want12 = 1, fail = 0;
    if (argc > 1) { want11 = !strcmp(argv[1], "11"); want12 = !strcmp(argv[1], "12"); }
    if (want11) fail |= probe_d3d11();
    if (want12) fail |= probe_d3d12();
    fflush(stdout);
    return fail;
}
