package analyze

import (
	"crypto/sha256"
	_ "embed"
	"encoding/json"
	"fmt"
	"go/types"
	"path/filepath"
)

//go:embed stdlib_ja.json
var stdlibJapaneseJSON []byte

type stdlibTranslationCatalog struct {
	GoVersion    string            `json:"go_version"`
	Translations map[string]string `json:"translations"`
}

var stdlibJapaneseCatalog = func() stdlibTranslationCatalog {
	var catalog stdlibTranslationCatalog
	if err := json.Unmarshal(stdlibJapaneseJSON, &catalog); err != nil {
		panic("invalid embedded Japanese SDK catalog: " + err.Error())
	}
	return catalog
}()

// Catalog keys use the exact Doc.Text(), including its trailing newline.
func japaneseFunctionSummary(fn *types.Func, filename, documentation string) string {
	if fn.Pkg() == nil || !sdkDirectory(filepath.Dir(filename)) {
		return ""
	}
	if translated := stdlibJapaneseCatalog.Translations[fmt.Sprintf("%x", sha256.Sum256([]byte(documentation)))]; documentation != "" && translated != "" {
		return translated
	}
	// The older glossary identifies free functions only, never same-named methods.
	if signature, ok := fn.Type().(*types.Signature); !ok || signature.Recv() != nil {
		return ""
	}
	return japaneseStandardFunctions[fn.Pkg().Path()+"."+fn.Name()]
}

var japaneseStandardFunctions = map[string]string{
	"os/signal.NotifyContext": `NotifyContext は親コンテキストのコピーを返します。このコンテキストは、指定したシグナルのいずれかを受信したとき、返された stop 関数が呼び出されたとき、または親コンテキストの Done チャネルが閉じられたときのうち、最初に起きた時点で完了状態（Done チャネルが閉じた状態）になります。

stop 関数はシグナルの処理登録を解除します。これは signal.Reset と同様に、そのシグナルに対する既定の動作を復元する場合があります。たとえば、Go プログラムが os.Interrupt を受信したときの既定の動作は終了です。NotifyContext(parent, os.Interrupt) を呼ぶと、この動作は返されたコンテキストをキャンセルする動作に変わります。返された stop 関数を呼ぶまでは、その後に割り込みを受信しても既定の動作（終了）は実行されません。

シグナルによって返されたコンテキストがキャンセルされた場合、そのコンテキストに対して context.Cause を呼ぶと、そのシグナルを説明するエラーが返されます。

stop 関数は関連するリソースを解放します。そのため、このコンテキストで実行する処理が完了し、シグナルをこのコンテキストへ振り向ける必要がなくなったら、できるだけ早く stop を呼ぶようにしてください。`,
	"fmt.Print":           "引数を既定の形式で標準出力へ書き込みます。隣接する引数が両方とも文字列でない場合は間に空白を入れます。末尾に改行は追加しません。書き込んだバイト数とエラーを返します。",
	"fmt.Printf":          "書式文字列に従って引数を整形し、標準出力へ書き込みます。書き込んだバイト数とエラーを返します。改行が必要な場合は書式に含めます。",
	"fmt.Println":         "引数を既定の形式で標準出力へ書き込みます。引数の間に空白を入れ、末尾に改行を追加します。書き込んだバイト数とエラーを返します。",
	"fmt.Sprint":          "引数を既定の形式で整形した文字列を返します。隣接する引数が両方とも文字列でない場合は間に空白を入れます。標準出力には書き込みません。",
	"fmt.Sprintf":         "書式文字列に従って引数を整形した文字列を返します。標準出力には書き込みません。",
	"fmt.Sprintln":        "引数を既定の形式で整形した文字列を返します。引数の間に空白を入れ、末尾に改行を追加します。標準出力には書き込みません。",
	"fmt.Fprintf":         "書式文字列に従って引数を整形し、指定された io.Writer へ書き込みます。書き込んだバイト数とエラーを返します。",
	"fmt.Fprintln":        "引数の間に空白、末尾に改行を加えて、指定された io.Writer へ書き込みます。書き込んだバイト数とエラーを返します。",
	"fmt.Errorf":          "書式文字列に従ってメッセージを整形し、error を返します。%w を使うと、その引数のエラーをラップできます。",
	"errors.New":          "指定した文字列をメッセージとする新しいエラーを返します。同じ文字列を渡しても、呼び出すたびに別のエラーになります。",
	"errors.Is":           "エラー自身と Unwrap でたどれるエラー群に、指定した対象と一致するものがあるかを調べます。エラー型の Is メソッドによる一致判定にも対応します。",
	"errors.As":           "エラー自身と Unwrap でたどれるエラー群から、target が指す型へ代入できるエラーを探します。見つかると target へ設定して true を返します。エラー型の As メソッドによる変換にも対応します。target は通常、受け取り先変数へのポインタです。",
	"strings.Contains":    "文字列に指定した部分文字列が含まれるかを返します。空の部分文字列は、どの文字列にも含まれると判定します。",
	"strings.HasPrefix":   "文字列が指定した接頭辞で始まるかを返します。",
	"strings.HasSuffix":   "文字列が指定した接尾辞で終わるかを返します。",
	"strings.TrimSpace":   "文字列の先頭と末尾から、Unicode で空白と定義される文字を取り除いた文字列を返します。途中の空白は残します。",
	"strings.Split":       "文字列を指定した区切り文字列で分割し、文字列のスライスを返します。区切りが空の場合は UTF-8 の各文字で分割します。文字列と区切りが両方とも空の場合は空のスライスを返します。",
	"strings.Join":        "文字列スライスの要素を、指定した区切り文字列を間に挟んで連結します。",
	"strings.ReplaceAll":  "文字列中の old と一致する重なりのない部分を、すべて new に置き換えた文字列を返します。",
	"strings.ToUpper":     "文字列中の Unicode 文字を対応する大文字へ変換した文字列を返します。",
	"strings.ToLower":     "文字列中の Unicode 文字を対応する小文字へ変換した文字列を返します。",
	"strconv.Atoi":        "10進整数を表す文字列を int に変換します。形式が不正な場合や int の範囲を超える場合はエラーを返します。",
	"strconv.Itoa":        "int の値を10進表記の文字列に変換します。",
	"strconv.ParseInt":    "指定した基数とビット数に従って文字列を符号付き整数へ変換し、int64 とエラーを返します。基数に0を指定すると、文字列の接頭辞などから基数を判定します。",
	"strconv.FormatInt":   "int64 の値を指定した基数（2〜36）の文字列へ変換します。",
	"os.ReadFile":         "指定したファイル全体を読み込み、バイトスライスとエラーを返します。成功時のエラーは nil で、ファイル末尾への到達自体はエラーになりません。",
	"os.WriteFile":        "指定したファイルへバイト列を書き込みます。ファイルがなければ perm に従って作成し、既存ファイルは内容を切り詰めて上書きします。途中で失敗した場合、部分的に書き込まれた状態になることがあります。",
	"os.Open":             "指定したファイルを読み取り用に開きます。成功した場合、呼び出し側で Close して閉じる必要があります。",
	"os.Create":           "指定したファイルを作成して読み書き用に開きます。既存ファイルは内容を切り詰めます。成功した場合、呼び出し側で Close して閉じる必要があります。",
	"os.Getenv":           "環境変数の値を返します。変数が未設定の場合は空文字列を返します。未設定と空の値を区別するには LookupEnv を使います。",
	"os.LookupEnv":        "環境変数の値と、その変数が設定されているかを示す真偽値を返します。空の値と未設定を区別できます。",
	"os.ReadDir":          "指定したディレクトリのエントリを、ファイル名でソートしたスライスとして返します。読み込み途中でエラーが発生した場合は、読み込めたエントリとエラーを返します。",
	"path/filepath.Join":  "空の要素を無視してパス要素を OS 固有の区切り文字で連結し、結果を Clean で整理します。ファイルの存在確認はしません。",
	"path/filepath.Clean": "パス文字列の余分な区切りや .、処理可能な .. を字句的に整理します。ファイルシステムへのアクセスやシンボリックリンクの解決は行いません。",
	"path/filepath.Base":  "パスの最後の要素を返します。空のパスに対しては . を返します。",
	"path/filepath.Dir":   "パスの最後の要素を除いたディレクトリ部分を、Clean で整理して返します。",
	"path/filepath.Abs":   "相対パスを現在の作業ディレクトリに基づいて絶対パスへ変換します。シンボリックリンクの解決は行いません。",
	"time.Now":            "現在のローカル時刻を time.Time として返します。経過時間の測定に使える単調増加時計の情報も含まれます。",
	"time.Sleep":          "現在の goroutine を、指定した時間以上停止します。時間が0以下の場合は直ちに戻ります。",
}
