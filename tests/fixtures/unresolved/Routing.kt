package com.example.unresolved

import io.ktor.server.application.*
import io.ktor.server.response.*
import io.ktor.server.routing.*

fun Application.configureRouting() {
    routing {
        route("/api/v1") {
            sessionAuthRoutes()
            brandingThemePublicRoute()

            route("/things") {
                get("/") {
                    doSomeBusinessLogic()
                    call.respond("ok")
                }
            }
        }
    }
}

fun doSomeBusinessLogic() {}
