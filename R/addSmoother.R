addXYsmoother <- function(obj, opts, col.args, xlim, ylim) {
    ## decide what x and y are:
    if ("svy" %in% names(obj)) {
        if (is_survey(obj$svy)) {
            x <- obj$svy
            y <- NULL
        } else {
            # na's arent removed
            x <- obj$svy$x
            y <- obj$svy$y
            isna <- is.na(x) | is.na(y)
            x <- x[!isna]
            y <- y[!isna]
        }
    } else if ("args" %in% names(obj)) {
        x <- obj$args$df$x
        y <- obj$args$df$y
        isna <- is.na(x) | is.na(y)
        x <- x[!isna]
        y <- y[!isna]
    } else {
        x <- obj$x
        y <- obj$y
    }

    if (length(opts$quant.smooth) > 0) {
        if (is_survey(x))
            X <- x
        else
            X <- cbind(x, y)

        qs <- try(calcQSmooth(X, opts$quant.smooth, opts), silent = TRUE)
        if (!inherits(qs, "try-error")) {
            qp <- qs$qp
            lty <- qs$lty
            lwd <- qs$lwd
            for (q in 1:length(qp)) {
                try(
                    addQuantileSmoother(x, y,
                        quantile = qp[q],
                        col = opts$col.smooth,
                        lty = lty[q],
                        lwd = lwd[q],
                        opts = opts
                    ),
                    silent = TRUE
                )
            }
        }
    } else if (!is.null(opts$smooth)) {
      # Smoothers
        if (opts$smooth != 0) {
            if (opts$smooth > 1) {
                warning("Smoothing value must be in the interval [0, 1]")
            } else {
                if (length(unique(obj$col)) == 1 | !opts$trend.by) {
                    try(
                        addSmoother(x, y,
                            f = opts$smooth,
                            col = opts$col.smooth,
                            bs = opts$bs.inference,
                            opts = opts
                        ),
                        silent = TRUE
                    )
                } else {
                    byy <- as.factor(obj$col)  # pseudo-by-variable
                    xtmp <- lapply(levels(byy),
                        function(c) {
                            x[obj$col == c & !is.na(obj$col)]
                        }
                    )
                    ytmp <- lapply(levels(byy),
                        function(c) {
                            y[obj$col == c & !is.na(obj$col)]
                        }
                    )

                    for (b in 1:length(levels(byy))) {
                        try(
                            addSmoother(xtmp[[b]], ytmp[[b]],
                                f = opts$smooth,
                                col = darken(col.args$f.cols[b]),
                                bs = FALSE,
                                lty = opts$smoothby.lty,
                                opts = opts
                            ),
                            silent = TRUE
                        )
                    }
                }
            }
        }
    }
}

addSmoother <- function(x, y = NULL, f, col, bs, lty = 1, opts) {
    if (is.null(y) & is_survey(x)) {
        xr <- range(x$variables$x, na.rm = TRUE)
        bw <- f * sqrt(diff(xr))
        sm <- svysmooth(y ~ x, design = x, method = "locpoly", bandwidth = bw)[[1]]
    } else {
        sm <- loess.smooth(x, y, span = f, family = "gaussian")
    }
    grid.lines(sm$x, sm$y,
        default.units = "native",
        gp = gpar(col = col, lwd = 2 * opts$lwd, lty = lty),
        name = paste("inz-smoother", opts$rowNum, opts$colNum, sep = ".")
    )

    if (bs) {
        for (i in 1:30) {
            # User wants bootstrap inference for the smoother:
            id <- sample(1:length(x), replace = TRUE)
            x2 <- x[id]
            y2 <- y[id]
            sm <- lowess(x2, y2, f = f)
            grid.lines(sm$x, sm$y,
                default.units = "native",
                gp = gpar(col = col, lwd = 1 * opts$lwd, lty = 3),
                name = paste("inz-bs-smoother", opts$rowNum, opts$colNum, sep = ".")
            )
        }
    }
}

addQuantileSmoother <- function(x, y = NULL, quantile, col, lty, lwd, opts) {
    # Draws quantiles on a plot.
    if (quantile < 0.5)  # symmetry
        quantile <- c(quantile, 1 - quantile)

    # Because we are using the `svysmooth()` function from the `survey` package,
    # we need to supply a design (here, everything is IID)
    if (is.null(y) & is_survey(x))
        des <- x
    else
        des <- suppressWarnings(
            svydesign(ids = ~1,
                data = data.frame(x = x, y = y, stringsAsFactors = TRUE)
            )
        )

    invisible(
        sapply(quantile,
            function(a) {
                s <- svysmooth(y ~ x,
                    design = des,
                    method = "quantreg",
                    quantile = a
                )
                s <- s$x
                grid.lines(s$x, s$y,
                    default.units = "native",
                    gp = gpar(col = col, lty = lty, lwd = lwd * opts$lwd),
                    name = paste(
                        paste0("inz-quant-smooth-", a),
                        opts$rowNum,
                        opts$colNum,
                        sep = "."
                    )
                )
            }
        )
    )
}


calcQSmooth <- function(xy, q, opts) {
    if (is_survey(xy)) {
        x <- xy$variables[, c("x", "y")]
        x <- x[!apply(x, 1, function(y) any(is.na(y))), ]
    } else {
        x <- xy[!apply(xy, 1, function(y) any(is.na(y))), ]
    }

  # check quantiles are correct:
    if (q[1] == "default") {
        qp <- 0.5
        if (nrow(x) > opts$quant.cutoff[1]) qp <- c(qp, 0.25)
        if (nrow(x) > opts$quant.cutoff[2]) qp <- c(qp, 0.1)
    } else {
        qp <- q
    }

    if (any(qp < 1 & qp > 0)) {
        qp <- qp[qp > 0 & qp < 1]  # remove invalid quantiles

        qp[qp > 0.5] <- qp[qp > 0.5] - 0.5  # symmetry!
      # incase user gives c(0.25, 0.75), remove duplicates
        qp <- sort(unique(qp), decreasing = TRUE)

      # Sort out the line type and width:
        nn <- length(qp)
      # bb: the base number of repeats for each unit
        bb <- rep(nn %/% 3, 3)
        be <- nn %% 3  # which units repeated once more
        q.reps <- bb
        if (be != 0) q.reps[1:be] <- q.reps[1:be] + 1
        lty <- rep(1:3, q.reps)

      # Line width (less complicated! ...)
        lwd <- rep(1, length(qp))
        lwd[1] <- 2
        if (length(x) > opts$large.sample.size)
            lwd <- lwd + 1

        qs <- list(qp = qp,
                   lty = lty,
                   lwd = lwd)
    } else {
        qs <- NULL
    }

    qs
}
