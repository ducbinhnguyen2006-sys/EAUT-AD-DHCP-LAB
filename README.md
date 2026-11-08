# EAUT-AD-DHCP-LAB

Bộ script PowerShell 5.1 tự động hóa bài lab Windows Server: dựng Domain Controller
`binhnd363.edu.vn`, cài DHCP và cấp phát IP động cho máy client `WRK01`.

- Server: `EAUT-SRV12` - `192.168.63.2/24` - DNS `192.168.63.2` - không gateway
- Client: `WRK01` - static tạm `192.168.63.10/24` khi join domain, sau đó chuyển DHCP
- DHCP scope: `EAUT-LAB-63`, `192.168.63.100` - `192.168.63.200`, lease 8 ngày
- Domain/NetBIOS: `binhnd363.edu.vn` / `BINHND363`
- Log trên từng VM: `LOGS\SERVER` và `LOGS\CLIENT` (tương đối theo thư mục dự án)

Quy trình chuẩn chỉ có **hai lệnh gốc**:

```powershell
# Trên Windows Server
.\START-SERVER.ps1

# Trên Windows 10 client, sau khi server báo READY
.\START-CLIENT.ps1
```

Các file trong `SERVER\` và `CLIENT\` là các bước nội bộ do hai lệnh trên gọi tự động.
Không chạy thủ công các bước đó trong quy trình chuẩn.

## 1. Cấu trúc thư mục

```text
EAUT-AD-DHCP-LAB\
  START-SERVER.ps1             # entry point duy nhất trên server
  START-CLIENT.ps1             # entry point duy nhất trên client
  CONFIG\LabConfig.psd1        # nguồn tham số duy nhất (IP, domain, scope, log)
  LIB\LabCommon.psm1           # hàm dùng chung
  LIB\LabOrchestrator.psm1     # state, checkpoint, reboot/resume, task scheduler
  SERVER\01-Server-Prepare.ps1 # IP tĩnh, DNS, bỏ gateway, rename
  SERVER\02-Install-ADDS.ps1   # cài AD DS + DNS, tạo forest
  SERVER\03-Verify-AD.ps1      # kiểm tra AD/DNS (chỉ đọc)
  SERVER\04-Install-DHCP.ps1   # cài DHCP, authorize trong AD
  SERVER\05-Configure-DHCP.ps1 # tạo scope + options 006/015, bỏ 003
  SERVER\06-Verify-Server.ps1  # kiểm tra server độc lập (chỉ đọc)
  CLIENT\01-Client-Prepare.ps1 # IP tĩnh tạm, DNS, rename WRK01
  CLIENT\02-Join-Domain.ps1    # join domain bằng credential nhập tay
  CLIENT\03-Configure-DHCP.ps1 # chuyển adapter sang DHCP, xin lease
  CLIENT\04-Verify-Client.ps1  # kiểm tra client độc lập (chỉ đọc)
  STATE\                       # state/checkpoint của từng VM (tự tạo)
  LOGS\SERVER\                 # log của server
  LOGS\CLIENT\                 # log của client
  README.md
```

Phải copy **toàn bộ cây thư mục** sang từng VM (giữ nguyên `CONFIG`, `LIB`,
`SERVER`, `CLIENT`). Script không phụ thuộc ổ D:, có thể đặt ở Desktop hoặc C:.

## 2. Chuẩn bị trên máy host (VMware Workstation)

1. Snapshot cả hai VM ở trạng thái Lab 1 (trước khi chạy bất kỳ script nào).
2. Gắn cả hai VM vào **VMnet3 - Host-only**:
   - VM Settings > Network Adapter > Custom: `VMnet3`.
3. Tắt DHCP của VMware trên VMnet3:
   - Mở **Virtual Network Editor** bằng quyền Administrator.
   - Chọn `VMnet3`, bỏ chọn **Use local DHCP service**, Apply/OK.
4. Cấu hình subnet của VMnet3 đúng là `192.168.63.0/255.255.255.0`; không dùng một
   subnet khác. Đặt IP host của adapter VMnet3 trên máy host là `192.168.63.1` hoặc
   `192.168.63.254` (không dùng `.2`, `.10`, hoặc dải `.100`-`.200`).
5. Bật cả hai VM, đăng nhập bằng tài khoản Administrator cục bộ.

Lưu ý: không cần Internet cho lab này. Cấu hình **không có default gateway** là cố ý,
chỉ lưu thông trong `192.168.63.0/24`.

## 3. Chuẩn bị PowerShell trên mỗi VM

Mở **Windows PowerShell (Run as Administrator)**, tại thư mục đã copy:

```powershell
Get-ChildItem -Recurse -Include *.ps1,*.psm1,*.psd1 | Unblock-File
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Không đổi ExecutionPolicy vĩnh viễn. Không chạy script qua RDP khi đang đổi IP của
chính adapter đó - dùng VMware console.

## 4. Triển khai server

Tại thư mục dự án trên Windows Server, chạy:

```powershell
.\START-SERVER.ps1
```

Script tự động:

1. Kiểm tra quyền Administrator và PowerShell 5.1.
2. Đọc trạng thái thật của máy trước khi quyết định: standalone, role đã cài nhưng chưa
   promote, promotion đang dở, DC đã hoạt động, hoặc trạng thái không an toàn.
3. Nếu máy đã là DC, **không tạo lại forest**. Script đặt lại DNS client về
   `192.168.63.2` nếu cần, chạy `03-Verify-AD.ps1`, rồi cài/cấu hình DHCP.
4. Nếu máy chưa promote, chạy `01`, `02`, tự reboot khi cần và tự resume sau khi
   Administrator đăng nhập lại.
5. Chạy 13 kiểm tra cuối bắt buộc và chỉ in
   `SERVER IS READY FOR CLIENT DEPLOYMENT` khi tất cả đạt PASS.

Lần chạy đầu có thể hỏi:

- Mật khẩu DSRM (tối thiểu 7 ký tự, đủ 3 trong 4 nhóm ký tự). Mật khẩu không được ghi
  vào file hay log.
- Gõ đúng `CREATE` để xác nhận tạo forest. Nếu không xác nhận, script dừng trước khi
  cài role/promote.

Nếu script yêu cầu reboot, nó đã đăng ký task resume và sẽ tự khởi động lại. Sau khi
máy lên, **đăng nhập lại bằng tài khoản thuộc Administrators** (trên DC là
`BINHND363\Administrator`) để task tiếp tục. Không tắt VM và không đóng VMware console
trong lúc chờ.

Các chế độ chỉ đọc:

```powershell
.\START-SERVER.ps1 -Status   # xem state + trạng thái thật, không sửa cấu hình
.\START-SERVER.ps1 -Verify   # chạy 13 kiểm tra cuối, không sửa cấu hình
```

`-Resume` dùng khi cần tiếp tục thủ công một lần chạy bị gián đoạn:

```powershell
.\START-SERVER.ps1 -Resume
```

## 5. Triển khai client

Chỉ chạy sau khi server in `SERVER IS READY FOR CLIENT DEPLOYMENT`. Trên Windows 10
client, tại thư mục dự án:

```powershell
.\START-CLIENT.ps1
```

Script tự động:

1. Kiểm tra client có đang ở baseline Lab 1 hoặc đã ở trạng thái đích hay không.
2. Đặt tên `WRK01`, IP tĩnh tạm `192.168.63.10/24`, DNS `192.168.63.2`, bỏ gateway.
3. Tự reboot khi cần và tự resume sau khi Administrator đăng nhập lại.
4. Join domain bằng tài khoản Domain Admin nhập tay; hỏi gõ `JOIN` để xác nhận.
5. Tự reboot sau join, sau đó chuyển adapter sang DHCP và xin lease trong dải
   `192.168.63.100`-`.200`.
6. Kiểm tra domain, secure channel, DHCP lease, DHCP server, DNS, DNS suffix, DC
   connectivity và in `LAB DEPLOYMENT SUCCESSFUL` khi tất cả đạt PASS.

Trong lúc chạy, nhập `BINHND363\Administrator` (hoặc Domain Admin khác) khi được hỏi.
Mật khẩu không được ghi vào file hay log. Sau khi join, đăng nhập lại bằng tài khoản
domain thuộc Administrators để task resume tiếp tục.

Các chế độ chỉ đọc:

```powershell
.\START-CLIENT.ps1 -Status   # xem state + trạng thái thật, không sửa cấu hình
.\START-CLIENT.ps1 -Verify   # chạy kiểm tra cuối, không sửa cấu hình
```

Tiếp tục thủ công khi bị gián đoạn:

```powershell
.\START-CLIENT.ps1 -Resume
```

## 6. State, reboot và resume

- State server: `STATE\server-state.json`
- State client: `STATE\client-state.json`
- Task resume server: `EAUT-Lab-SERVER-Resume`
- Task resume client: `EAUT-Lab-CLIENT-Resume`

Task resume chạy khi Administrator đăng nhập, dùng cửa sổ PowerShell bình thường để các
prompt DSRM/credential vẫn hiển thị. Task không lưu mật khẩu trong arguments. Task được
tự xóa khi thành công hoặc khi script dừng có kiểm soát.

Giới hạn chống lặp reboot: tối đa 4 lần tự reboot cho mỗi giai đoạn. Nếu vượt quá, script
dừng và yêu cầu kiểm tra log/state trước khi chạy tiếp.

Không xóa `STATE\*.json` khi đang triển khai. Nếu file state bị hỏng, script vẫn dùng
trạng thái thật của máy để quyết định và tạo bản backup `.corrupt_<timestamp>.json`.
Không có state không có nghĩa là phải tạo lại forest.

## 7. Exit code

| Code | Ý nghĩa | Hành động |
|------|---------|-----------|
| 0 | `START-*` thành công | Làm bước tiếp theo |
| 2 | `START-*` thất bại hoặc kiểm tra FAIL | Đọc log, chạy `-Status`, xử lý rồi `-Resume` |
| 3 | Chỉ là exit code nội bộ của script con: cần reboot | `START-*` xử lý tự động; không dùng mã này làm kết quả cuối |

## 8. Troubleshooting

| Hiện tượng | Nguyên nhân thường gặp | Xử lý |
|-----------|------------------------|-------|
| Server báo `Unsafe AD DS promotion state` | Có dấu hiệu promote dở, NTDS/DB tồn tại nhưng chưa phải DC hoạt động | Không chạy lại promote mù. Reboot, xem `LOGS\SERVER`, chạy `-Status`; nếu vẫn lỗi, khôi phục Snapshot Lab 1 |
| Server báo DC role nhưng AD DS không truy cập được | Promote chưa xong, DNS/service lỗi, hoặc chưa reboot | Reboot nếu vừa promote; kiểm tra DNS client `.2`, service NTDS/DNS; chạy `-Resume` |
| DNS client trên DC là `127.0.0.1` | `Install-ADDSForest` đổi DNS client trong lúc promote | `START-SERVER` tự đặt lại `.2`; kiểm tra lại bằng `-Verify` |
| Server dừng vì chưa gõ đúng `CREATE` | Xác nhận chạy trước bước cài role | Chạy lại `START-SERVER.ps1`; chưa có role/forest nào bị thay đổi bởi lần chạy đó |
| Server reboot nhưng không tự tiếp tục | Chưa có Administrator đăng nhập, hoặc task bị xóa | Đăng nhập bằng tài khoản Administrators; nếu cần chạy `.\START-SERVER.ps1 -Resume` |
| Client dừng vì chưa gõ đúng `JOIN` | Chưa xác nhận join | Chạy lại `START-CLIENT.ps1` hoặc `-Resume`; chưa join |
| Client báo computer account đã tồn tại | Object `WRK01` cũ trong AD | Trên DC kiểm tra `Get-ADComputer -Identity WRK01`; nếu chắc chắn cũ, xóa tay rồi chạy lại. Script không tự xóa |
| Client join được nhưng secure channel lỗi | Object stale hoặc trùng tên/MAC | Trên client thử `Test-ComputerSecureChannel -Repair -Credential (Get-Credential BINHND363\Administrator)` rồi reboot; hoặc xử lý object trên DC |
| Client không nhận lease | VMware DHCP còn bật, scope chưa Active, DHCP chưa authorize, firewall chặn UDP 67/68 | Kiểm tra mục 2; trên server chạy `-Verify`; không tự tắt toàn bộ firewall |
| Client nhận lease nhưng sai DHCP server | VMware DHCP hoặc DHCP server khác còn hoạt động | Tắt DHCP VMware trên VMnet3; kiểm tra `Get-DhcpServerInDC`; chạy lại client |
| Client DHCP FAIL | Không xin được lease hoặc lease không đến từ `.2` | Script tự khôi phục static `.10` + DNS `.2`; sửa lỗi rồi `-Resume` |
| `-Verify` báo DNS client sai | `-Verify` là chỉ đọc, không tự sửa | Chạy `START-*.ps1` ở chế độ deploy hoặc `-Resume` để sửa |
| Không kết nối được giữa hai VM | Khác mạng hoặc VMware DHCP còn bật | Cả hai cùng VMnet3 host-only; tắt DHCP VMware; kiểm tra IP `.2`/`.10` |

Log chi tiết nằm trong `LOGS\SERVER\START-SERVER_*.log`, `LOGS\SERVER\0x-*.log`,
`LOGS\CLIENT\START-CLIENT_*.log`, và `LOGS\CLIENT\0x-*.log`.

## 9. An toàn và giới hạn

- Không tự xóa scope/AD object, không tự unjoin domain, không tự tạo lại forest.
- `START-SERVER` kiểm tra trạng thái thật trước khi promote. Nếu promotion đã bắt đầu và
  có dấu hiệu dở dang, script dừng thay vì chạy lại mù.
- Forest promotion và join domain không có rollback. Nếu promotion lỗi giữa chừng, cách
  chắc chắn nhất là khôi phục Snapshot Lab 1.
- Mật khẩu chỉ được hỏi tại thời điểm chạy, không lưu trong `LabConfig.psd1`, state hay log.
- Không tự tắt firewall. Nếu firewall chặn AD/DHCP/DNS, kiểm tra rule và xử lý thủ công
  theo baseline của lab.
- `START-SERVER -Status` và `START-CLIENT -Status` chỉ đọc trạng thái; không sửa cấu hình,
  state hay task. `-Verify` cũng không sửa cấu hình.
- Chỉ sửa `CONFIG\LabConfig.psd1` **trước lần deploy đầu tiên**. Sau khi đã tạo AD/domain
  hoặc DHCP scope, không đổi IP/domain/scope rồi chạy lại các bước cũ; hãy khôi phục
  Snapshot Lab 1 để làm lại, hoặc dùng quy trình rebuild/domain-rename riêng.

## 10. Checklist bằng chứng nộp bài

- [ ] `START-SERVER.ps1` -> `SERVER IS READY FOR CLIENT DEPLOYMENT`
- [ ] `START-SERVER.ps1 -Verify` -> PASS, có scope `EAUT-LAB-63`, option 006/015, không 003
- [ ] `START-CLIENT.ps1` -> `LAB DEPLOYMENT SUCCESSFUL`
- [ ] `START-CLIENT.ps1 -Verify` -> PASS, IP trong `192.168.63.100`-`.200`
- [ ] `START-SERVER.ps1 -Verify` chạy lại sau client -> vẫn PASS
- [ ] Ảnh/log `ipconfig /all` trên WRK01 và `Get-DhcpServerv4Lease` trên server
