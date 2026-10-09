;************************************************************************
;
; ProDOS ROM-Drive read-only SOS driver for Apple ///
;
; This is a read-only SOS driver for Terence Boldt's ProDOS ROM-Drive card
; (https://github.com/tjboldt/ProDOS-ROM-Drive)
;
; Card protocol:
;   high latch = (block >> 3) & $FF
;   low latch  = (block << 5) & $FF, then increment 16 bytes
;   read each group from $C080 + slot*16 through base+15
;
;************************************************************************

;************************************************************************
; Equates - SOS System Calls
;************************************************************************

ExtPG           = $1401         ; Driver extended bank address offset
AllocSIR        = $1913         ; Allocate system internal resource
DealcSIR        = $1916         ; Deallocate system internal resource
SysErr          = $1928         ; Report system error
SELC800         = $1922

;************************************************************************
;* Equates - Zero Page Locations
;************************************************************************
ReqCode         = $C0           ; SOS request code
SOS_Unit        = $C1           ; Unit number (0-3)
CtlStat         = $C2           ; Control/Status code
CSList          = $C3           ; Control/Status list pointer (2 bytes)
SosBuf          = $C2           ; SOS buffer pointer
ReqCnt          = $C4           ; Requested byte count (2 bytes)
SosBlk          = $C6           ; Requested starting block number (2 bytes)
QtyRead         = $C8           ; POINTER to returned word, D_READ only

; Private scratch zero page: initialized during every request
IOAddr          = $D0           ; two bytes, X-byte at $14D1
BufPtr          = $D2           ; two bytes, X-byte at $14D3
Num_Blks        = $D4           ; one byte: at most 127 blocks per request
Remain          = $D5           ; two bytes: device capacity minus start
ResultPtr       = $D7           ; two bytes, X-byte at $14D8

;************************************************************************
; Equates - SOS Request Codes
;************************************************************************

SOS_Read        = $00           ; Read
SOS_Write       = $01           ; Write
SOS_Status      = $02           ; Status
SOS_Control     = $03           ; Control
SOS_Init        = $08           ; Initialize
SOS_Repeat      = $09           ; Repeat

;************************************************************************
; Equates - Error Codes
;************************************************************************

XDNFERR         = $10           ; Device not found
XBADDNUM        = $11           ; Bad device number
XREQCODE        = $20           ; Invalid request code
XCTLCODE        = $21           ; Invalid control code
XNORESRC        = $25           ; No resources available
XBADOP          = $26           ; Invalid operation
XNODRIVE        = $28           ; Drive not connected
XBYTECNT        = $2C           ; Byte count not 512
XBLKNUM         = $2D           ; Invalid block number
XNOWRITE        = $2B           ; Disk is write-protected

;************************************************************************
; Equates - Apple III Environment Register
;************************************************************************

EnvReg          = $FFDF
Clock1MHz       = $80
Clock2MHz       = $7F

;************************************************************************
; Equates - ProDOS ROM-Drive Card Interface
;************************************************************************

writeIoPortLow       = $C080    ; Write latch low (slot base + offset 0)
writeIoPortHigh      = $C081    ; Write latch high (slot base + offset 1)

;************************************************************************
; Equates - Device Constants
;************************************************************************

DriverVersion   = $1000         ; Version number
DriverMfgr      = $4453         ; Driver Manufacturer - David Schmidt (DS)
DriverType      = $80           ; Read-only
DriverSubtype   = $01           ; "First" subtype (no significance)
MaxBlock        = 2047          ; Maximum block number (2048 blocks total)

;************************************************************************
; Driver Comment Field
;************************************************************************

                .SEGMENT "TEXT"
                .WORD   $FFFF
                .WORD   COMMENT_END-COMMENT
COMMENT:        .BYTE   "Apple /// ROM-Drive Driver - by David Schmidt 2026"
COMMENT_END:

                .SEGMENT "DATA"

;************************************************************************
; Device Information Block (DIB)
;************************************************************************

DIB0:
DIB0_Link:      .WORD   $0000
DIB0_Entry:     .WORD   Entry
DIB0_Name:      .BYTE   $09
                .BYTE   ".ROMDRIVE      "
DIB0_Active:    .BYTE   $80               ; no buffer alignment required
DIB0_Slot:      .BYTE   $FF               ; 1..4 fixed slot; $FF = scan
DIB0_Unit:      .BYTE   $00
DIB0_Type:      .BYTE   DriverType
DIB0_SubType:   .BYTE   DriverSubtype
DIB0_Filler:    .BYTE   $00
DIB0_Blks:      .WORD   MaxBlock+1
                .WORD   DriverMfgr
                .WORD   DriverVersion
                .WORD   $0000             ; no configuration block

;************************************************************************
; Persistent Driver Variables
;************************************************************************

LastOP:         .BYTE   $FF               ; Last operation
LastReadBlks:   .BYTE   $00
LastReadValid:  .BYTE   $00
CardReady:      .BYTE   $00
ROMSlot:        .BYTE   $00               ; Calculated slot number
ScanMode:       .BYTE   $00
ProbeSlot:      .BYTE   $00
SIR_Addr:       .WORD   SIR_Tbl
SIR_Tbl:        .BYTE   $00               ; resource $10+slot
                .BYTE   $00               ; SOS resource owner ID
                .WORD   $0000             ; no interrupt handler
                .BYTE   $00               ; interrupt handler bank
SIR_Len         =       *-SIR_Tbl

BlockNum:       .WORD   $0000
HighLatch:      .BYTE   $00               ; High latch value
LowLatch:       .BYTE   $00               ; Low latch value
BlkHalfCtr:     .BYTE   $00               ; Block half counter (2, 1, 0)
PageByteCtr:    .BYTE   $00
Count:          .WORD   $0000

; Set only when FixUp temporarily maps bank-0 $00xx to $8F:$20xx.
; It distinguishes that alias from a caller-supplied $8F pointer.
BufZeroAlias:   .BYTE   $00

;************************************************************************
; Main entry / dispatcher
;
; Called by SOS to process all requests
;************************************************************************
Entry:
        CLD
        JSR     GoSlow

        LDA     SOS_Unit
        BEQ     EntryUnitOK
        LDA     #XBADDNUM
        SEC
        JMP     EntryFinish

EntryUnitOK:
        LDA     ReqCode
        CMP     #SOS_Repeat
        BEQ     EntryDispatch
        STA     LastOP                  ; last non-repeat operation
EntryDispatch:
        JSR     Dispatch
EntryFinish:
        JSR     GoFast                  ; preserves A and flags
        BCC     EntrySuccess
        ; Preserve error A while determining the error-return convention.
        PHA
        LDA     ReqCode
        CMP     #SOS_Init
        BEQ     EntryInitError
        PLA
        JSR     SysErr                  ; does not return
EntryInitError:
        PLA
        SEC
        RTS
EntrySuccess:
        LDA     #$00
        CLC
        RTS

;************************************************************************
; Request Dispatcher
;
; Routes requests based on ReqCode
;************************************************************************
DoTable:  .WORD     DRead-1          ; 0 Read request
          .WORD     DWrite-1         ; 1 Write request
          .WORD     DStatus-1        ; 2 Status request
          .WORD     DControl-1       ; 3 Control request
          .WORD     BadReq-1         ; 4 Unused
          .WORD     BadReq-1         ; 5 Unused
          .WORD     BadOp-1          ; 6 Open - valid for character devices
          .WORD     BadOp-1          ; 7 Close - valid for character devices
          .WORD     DInit-1          ; 8 Init request
          .WORD     DRepeat-1        ; 9 Repeat last read or write request

Dispatch:
        LDA     ReqCode
        CMP     #$0A                 ; Length of DoTable + 1
        BCS     BadReq
        ASL     A
        TAY
        LDA     DoTable+1,Y
        PHA
        LDA     DoTable,Y
        PHA
        RTS                          ; synthetic jump to request handler

BadReq:
        LDA     #XREQCODE
        SEC
        RTS
BadOp:
        LDA     #XBADOP
        SEC
        RTS
NoDevice:
        LDA     #XDNFERR
        SEC
        RTS

CheckReady:
        LDA     CardReady
        BEQ     NoDevice
        CLC
        RTS

;************************************************************************
; Initialization: verify configured slot, or scan 1..4 for signature.
; DIB slot is changed only after successful SIR allocation.
; CardReady prevents allocating the same SIR twice.
;************************************************************************
DInit:
        LDA     CardReady
        BEQ     InitNew
        CLC
        RTS
InitNew:
        LDA     #$00
        STA     ScanMode
        LDA     DIB0_Slot
        CMP     #$FF
        BEQ     InitAuto
        CMP     #$01
        BCC     InitNotFound
        CMP     #$05
        BCS     InitNotFound
        STA     ProbeSlot
        JMP     InitProbe
InitAuto:
        LDA     #$01
        STA     ScanMode
        STA     ProbeSlot
InitProbe:
        JSR     CheckSig
        BCC     InitAllocate
        LDA     ScanMode
        BEQ     InitNotFound
        INC     ProbeSlot
        LDA     ProbeSlot
        CMP     #$05
        BCC     InitProbe
InitNotFound:
        LDA     #XDNFERR
        SEC
        RTS

InitAllocate:
        LDA     ProbeSlot
        ORA     #$10
        STA     SIR_Tbl
        LDA     #SIR_Len
        LDX     SIR_Addr
        LDY     SIR_Addr+1
        JSR     AllocSIR
        BCS     InitNoResource
        ; AllocSIR leaves A/X/Y undefined; do not save A as a SIR number.
        LDA     ProbeSlot
        STA     DIB0_Slot
        STA     ROMSlot
        LDA     #$01
        STA     CardReady
        LDA     #$00
        STA     LastReadValid
        CLC
        RTS
InitNoResource:
        LDA     #XNORESRC
        SEC
        RTS

; Compare the original four-byte signature at $Cs08.
; This is a firmware heuristic, not a guaranteed unique hardware ID.
; Use SELC800 while probing: other cards may select expansion ROM on
; a $Cnxx access. No expansion ROM or card firmware is executed.
CheckSig:
        LDA     ProbeSlot
        JSR     SELC800
        LDA     #$00
        STA     BufPtr+ExtPG         ; ordinary slot-ROM address
        LDA     ProbeSlot
        ORA     #$C0
        STA     BufPtr+1
        LDA     #$08
        STA     BufPtr
        LDY     #$03
CheckSigByte:
        LDA     (BufPtr),Y
        CMP     Signature,Y
        BNE     CheckSigMiss
        DEY
        BPL     CheckSigByte
        CLC
        JMP     CheckSigRelease
CheckSigMiss:
        SEC
CheckSigRelease:
        PHP
        LDA     #$00
        JSR     SELC800              ; release expansion space
        PLP                          ; keep signature result
        RTS

;************************************************************************
; Read / repeat / write
;
; D_REPEAT has a new buffer and starting block but no new byte count
; and NO bytes-read output pointer. Retain the last successful read's
; block count. Do not overwrite ReqCode or any supplied pointer.
;************************************************************************
DRead:
        LDA     #$00
        STA     LastReadValid
        STA     Count
        STA     Count+1
        JSR     StoreQtyRead         ; initialize caller's count to zero
        JSR     CheckReady
        BCS     DReadReturn
        JSR     CkCnt
        BCS     DReadReturn
        LDA     Num_Blks
        STA     LastReadBlks
        JSR     ReadRequest
        BCS     DReadReturn
        LDA     #$01
        STA     LastReadValid
        CLC
DReadReturn:
        RTS

DRepeat:
        LDA     LastOP
        CMP     #SOS_Write
        BEQ     DWrite
        CMP     #SOS_Read
        BNE     RepeatBadOp
        LDA     LastReadValid
        BEQ     RepeatBadOp
        JSR     CheckReady
        BCS     RepeatReturn
        LDA     LastReadBlks
        STA     Num_Blks
        LDA     #$00
        STA     Count
        STA     Count+1
        JMP     ReadRequest
RepeatBadOp:
        LDA     #XBADOP
        SEC
RepeatReturn:
        RTS

DWrite:
        JSR     CheckReady
        BCS     WriteReturn
        LDA     #XNOWRITE
        SEC
WriteReturn:
        RTS

ReadRequest:
        LDA     Num_Blks
        BNE     ReadNonzero
        CLC                          ; zero bytes: no buffer/card access
        RTS
ReadNonzero:
        JSR     CvtBlk
        BCC     ReadRangeOK
        RTS
ReadRangeOK:
        LDA     SosBuf
        STA     BufPtr
        LDA     SosBuf+1
        STA     BufPtr+1
        LDA     SosBuf+ExtPG
        STA     BufPtr+ExtPG
        LDA     #$00
        STA     BufZeroAlias
        STA     IOAddr+ExtPG         ; ALWAYS ordinary slot I/O
        JSR     FixUp
        LDA     SosBlk
        STA     BlockNum
        LDA     SosBlk+1
        STA     BlockNum+1
ReadNextBlock:
        JSR     ReadBlock            ; advances BufPtr by 512
        INC     Count+1
        INC     Count+1
        JSR     StoreQtyRead         ; skipped for D_REPEAT
        INC     BlockNum
        BNE     ReadBlockAdvanced
        INC     BlockNum+1
ReadBlockAdvanced:
        DEC     Num_Blks
        BNE     ReadNextBlock
        CLC
        RTS

; ReqCnt must be a multiple of 512. A 16-bit count permits 0..127
; whole blocks, so Num_Blks deliberately occupies just one byte.
CkCnt:
        LDA     ReqCnt
        BNE     CountBad
        LDA     ReqCnt+1
        LSR     A
        BCS     CountBad
        STA     Num_Blks
        CLC
        RTS
CountBad:
        LDA     #XBYTECNT
        SEC
        RTS

; Called only for NONZERO transfers; all units are blocks
; Require Num_Blks <= DIB0_Blks - SosBlk
CvtBlk:
        SEC
        LDA     DIB0_Blks
        SBC     SosBlk
        STA     Remain
        LDA     DIB0_Blks+1
        SBC     SosBlk+1
        STA     Remain+1
        BCC     BlockBad
        LDA     Remain+1
        BNE     BlockOK                 ; >=256 blocks left, need <=127
        LDA     Remain
        CMP     Num_Blks
        BCC     BlockBad
BlockOK:
        CLC
        RTS
BlockBad:
        LDA     #XBLKNUM
        SEC
        RTS

;************************************************************************
; Read one 512-byte block using the Apple II card protocol.
;
; An unaligned buffer crossing
; $FCFF->$FD00 is normalized before the first store at the new page.
; The card still sees the same high/low latch values and 16-byte reads.
; X is the slot offset and is preserved by AdvanceBuf/FixUp.
;************************************************************************
ReadBlock:
        LDA     ROMSlot
        ASL     A
        ASL     A
        ASL     A
        ASL     A
        TAX

        LDA     BlockNum+1
        ASL     A
        ASL     A
        ASL     A
        ASL     A
        ASL     A
        STA     HighLatch
        LDA     BlockNum
        LSR     A
        LSR     A
        LSR     A
        ORA     HighLatch
        STA     HighLatch
        STA     writeIoPortHigh,X

        LDA     BlockNum
        ASL     A
        ASL     A
        ASL     A
        ASL     A
        ASL     A
        STA     LowLatch
        LDA     #$02
        STA     BlkHalfCtr
        LDA     #$C0
        STA     IOAddr+1
        LDY     #$00
Read256:
        LDA     #$00
        STA     PageByteCtr
ReadGroup:
        LDA     LowLatch
        STA     writeIoPortLow,X
        TXA
        ORA     #$80
        STA     IOAddr
Read16:
        LDA     (IOAddr),Y
        STA     (BufPtr),Y
        JSR     AdvanceBuf
        INC     PageByteCtr
        INC     IOAddr
        LDA     IOAddr
        AND     #$0F
        BNE     Read16
        INC     LowLatch
        LDA     PageByteCtr
        BNE     ReadGroup
        DEC     BlkHalfCtr
        BNE     Read256
        CLC
        RTS

;************************************************************************
; Status / control
;************************************************************************
DStatus:
        JSR     CheckReady
        BCC     StatusReady
        RTS
StatusReady:
        LDA     CtlStat
        BEQ     StatusZero
        CMP     #$FE
        BEQ     StatusBitmap
BadStatus:
        LDA     #XCTLCODE
        SEC
        RTS
StatusZero:
        JSR     CopyCSList
        LDA     #$02                    ; idle, write-protected
        LDY     #$00
        STA     (BufPtr),Y
        CLC
        RTS
StatusBitmap:
        JSR     CopyCSList
        LDA     #$FF
        LDY     #$00
        STA     (BufPtr),Y
        JSR     AdvanceBuf
        LDA     #$FF
        STA     (BufPtr),Y
        CLC
        RTS

; No hardware reset operation is defined for this card. Preserve the
; original policy: all D_CONTROL codes return invalid control code.
DControl:
        LDA     #XCTLCODE
        SEC
        RTS

CopyCSList:
        LDA     CSList
        STA     BufPtr
        LDA     CSList+1
        STA     BufPtr+1
        LDA     CSList+ExtPG
        STA     BufPtr+ExtPG
        LDA     #$00
        STA     BufZeroAlias
        JMP     FixUp

;************************************************************************
; Actual-byte-count output
;
; Save the live transfer pointer while using the same normalized byte
; store path for the two-byte result. QtyRead and its X-byte remain
; unchanged. No access whatsoever to QtyRead during D_REPEAT.
;************************************************************************
StoreQtyRead:
        LDA     ReqCode
        CMP     #SOS_Read
        BEQ     StoreQtyGo
        RTS
StoreQtyGo:
        LDA     BufPtr
        PHA
        LDA     BufPtr+1
        PHA
        LDA     BufPtr+ExtPG
        PHA
        LDA     BufZeroAlias
        PHA

        LDA     QtyRead
        STA     ResultPtr
        LDA     QtyRead+1
        STA     ResultPtr+1
        LDA     QtyRead+ExtPG
        STA     ResultPtr+ExtPG
        ; Copy all three pointer bytes BEFORE writing anything through
        ; the result pointer; the request table itself is left intact.
        LDA     ResultPtr
        STA     BufPtr
        LDA     ResultPtr+1
        STA     BufPtr+1
        LDA     ResultPtr+ExtPG
        STA     BufPtr+ExtPG
        LDA     #$00
        STA     BufZeroAlias
        JSR     FixUp
        LDY     #$00
        LDA     Count
        STA     (BufPtr),Y
        JSR     AdvanceBuf
        LDA     Count+1
        STA     (BufPtr),Y

        PLA
        STA     BufZeroAlias
        PLA
        STA     BufPtr+ExtPG
        PLA
        STA     BufPtr+1
        PLA
        STA     BufPtr
        RTS

;************************************************************************
; Extended indirect destination pointer handling
;
; Ordinary (X-byte bit7=0) and caller-supplied $8F pointers retain
; their normal CPU-space mapping. Other extended pointers use:
;   $00xx, bank N -> $80xx, bank N-1
;   $00xx, bank 0 -> $20xx, X-byte $8F (temporary alias)
;   $FDxx..$FFxx, bank N -> $7Dxx..$7Fxx, bank N+1
;
; $FD is the conservative threshold used in the SOS block-driver
; fixup pattern; these upper addresses have equivalent lower forms.
; X and Y are preserved; A and arithmetic flags are scratch.
;************************************************************************
AdvanceBuf:
        INC     BufPtr
        BNE     AdvanceDone
        INC     BufPtr+1
        LDA     BufZeroAlias
        BEQ     AdvanceNormal
        ; We have just left the special $8F:$20xx alias page.
        ; Resume normal bank-0 addressing at $80:$0100. Leaving it
        ; at $8F would eventually run into the system-bank mapping.
        LDA     #$00
        STA     BufZeroAlias
        LDA     #$01
        STA     BufPtr+1
        LDA     #$80
        STA     BufPtr+ExtPG
        RTS
AdvanceNormal:
        JMP     FixUp
AdvanceDone:
        RTS

FixUp:
        LDA     BufPtr+ExtPG
        BPL     FixDone                 ; extended addressing disabled
        CMP     #$8F
        BEQ     FixDone                 ; special system/bank-0 mapping
        LDA     BufPtr+1
        BEQ     FixLowPage
        CMP     #$FD
        BCC     FixDone
        AND     #$7F
        STA     BufPtr+1
        INC     BufPtr+ExtPG
        RTS
FixLowPage:
        LDA     BufPtr+ExtPG
        CMP     #$80
        BEQ     FixBankZero
        DEC     BufPtr+ExtPG
        LDA     #$80
        STA     BufPtr+1
        RTS
FixBankZero:
        LDA     #$20
        STA     BufPtr+1
        LDA     #$8F
        STA     BufPtr+ExtPG
        LDA     #$01
        STA     BufZeroAlias
FixDone:
        RTS

;************************************************************************
; Clock utilities: change only bit 7; preserve A and processor flags.
; All normal and error exits restore full speed as SOS requires.
;************************************************************************
GoSlow:
        PHP
        PHA
        LDA     EnvReg
        ORA     #Clock1MHz
        STA     EnvReg
        PLA
        PLP
        RTS
GoFast:
        PHP
        PHA
        LDA     EnvReg
        AND     #Clock2MHz
        STA     EnvReg
        PLA
        PLP
        RTS

Signature:
        .BYTE   $AD,$00,$C0,$C9

; End of driver
