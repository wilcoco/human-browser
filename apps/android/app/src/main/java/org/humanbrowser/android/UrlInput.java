package org.humanbrowser.android;

import android.net.Uri;
import java.net.IDN;
import java.util.Locale;

/** Address-bar normalization only; never rewrite stored evidence URLs. */
final class UrlInput {
    static String stripEdges(String input) {
        int start = 0, end = input.length();
        while (start < end && edge(input.charAt(start))) start++;
        while (end > start && edge(input.charAt(end - 1))) end--;
        return input.substring(start, end);
    }
    private static boolean edge(char c) {
        return Character.isWhitespace(c) || Character.isSpaceChar(c) || Character.getType(c) == Character.FORMAT;
    }
    static String fromInput(String input) {
        String value = stripEdges(input);
        if (value.length() > 8192) throw new IllegalArgumentException("주소가 너무 깁니다. 8,192자 이내로 입력해 주세요.");
        if (value.length() > 1 && ((value.startsWith("\"") && value.endsWith("\"")) || (value.startsWith("<") && value.endsWith(">"))))
            value = stripEdges(value.substring(1, value.length() - 1));
        if (value.startsWith("//")) value = "https:" + value;
        else if (value.matches("(?i)^(?:[^\\s/:?#]+\\.[^\\s/:?#]+|localhost|\\[[0-9a-f:]+\\])(?::[0-9]+)?(?:[/?#].*)?$"))
            value = "https://" + value;
        else if (!value.matches("(?s)^[A-Za-z][A-Za-z0-9+.-]*:.*"))
            return "https://duckduckgo.com/?q=" + Uri.encode(value);
        if (value.indexOf('\\') >= 0) throw new IllegalArgumentException("주소에 역슬래시가 있습니다. 주소를 확인해 주세요.");
        Uri uri = Uri.parse(value).normalizeScheme();
        if (!"https".equals(uri.getScheme()) && !"http".equals(uri.getScheme()))
            throw new IllegalArgumentException("웹 주소를 입력해 주세요. 이 주소 형식은 열 수 없습니다: " + uri.getScheme());
        if (uri.getUserInfo() != null)
            throw new IllegalArgumentException("사용자 정보가 포함된 주소는 열 수 없습니다. 사이트 주소만 입력해 주세요.");
        String authority = uri.getEncodedAuthority(), host = uri.getHost();
        if (host == null || host.isEmpty() || authority == null || authority.contains("\\") || authority.contains("%"))
            throw new IllegalArgumentException("사이트 주소를 확인해 주세요. 예: https://example.com");
        for (int i=0;i<authority.length();i++) if (edge(authority.charAt(i)))
            throw new IllegalArgumentException("사이트 이름 안에 공백이 있습니다. 주소를 확인해 주세요.");
        String port = "";
        int colon = authority.lastIndexOf(':');
        if (colon > authority.lastIndexOf(']')) {
            String digits = authority.substring(colon + 1);
            try {
                int n = Integer.parseInt(digits);
                if (!digits.matches("[0-9]+") || n < 1 || n > 65535) throw new NumberFormatException();
                port = ":" + digits;
            } catch (NumberFormatException e) { throw new IllegalArgumentException("주소의 포트 번호를 확인해 주세요."); }
        }
        try {
            if (!host.startsWith("[")) host = IDN.toASCII(host, IDN.USE_STD3_ASCII_RULES).toLowerCase(Locale.ROOT);
        } catch (IllegalArgumentException e) { throw new IllegalArgumentException("사이트 이름을 확인해 주세요."); }
        return uri.buildUpon().scheme("https").encodedAuthority(host + port).build().toString().replace(" ", "%20");
    }
    static boolean isHttps(String value) {
        if (value == null || value.length() > 8192) return false;
        try {
            Uri uri = Uri.parse(value);
            return "https".equalsIgnoreCase(uri.getScheme()) && uri.getHost() != null && !uri.getHost().isEmpty()
                && uri.getUserInfo() == null && !uri.getEncodedAuthority().contains("\\");
        } catch (Exception e) { return false; }
    }
}
