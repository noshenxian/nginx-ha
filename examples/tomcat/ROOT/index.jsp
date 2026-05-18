<%@ page import="java.net.InetAddress" %>
<%@ page contentType="text/plain; charset=UTF-8" pageEncoding="UTF-8" %>
<%
String hostname = InetAddress.getLocalHost().getHostName();
String sessionId = session.getId();
String forwardedFor = request.getHeader("X-Forwarded-For");
String requestId = request.getHeader("X-Request-ID");
%>
hostname=<%= hostname %>
session=<%= sessionId %>
path=<%= request.getRequestURI() %>
x-forwarded-for=<%= forwardedFor %>
x-request-id=<%= requestId %>
