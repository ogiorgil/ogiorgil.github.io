(function () {
	/* ---------- Greedy nav ---------- */
	var nav = document.querySelector(".greedy-nav");
	if (nav) {
		var btn = nav.querySelector("button");
		var visibleLinks = nav.querySelector(".visible-links");
		var hiddenLinks = nav.querySelector(".hidden-links");

		if (btn && visibleLinks && hiddenLinks) {
			var allItems = Array.prototype.slice.call(
				visibleLinks.querySelectorAll("li")
			);

			function updateNav() {
				// Reset: move everything back to visible
				allItems.forEach(function (li) {
					visibleLinks.appendChild(li);
				});
				hiddenLinks.classList.add("hidden");

				var availableWidth = nav.offsetWidth;
				var btnWidth = btn.offsetWidth + 10;

				while (
					visibleLinks.offsetWidth > availableWidth - btnWidth &&
					visibleLinks.children.length > 1
				) {
					var last = visibleLinks.lastElementChild;
					hiddenLinks.insertBefore(last, hiddenLinks.firstChild);
				}

				if (hiddenLinks.children.length) {
					hiddenLinks.classList.remove("hidden");
					btn.style.display = "";
				} else {
					btn.style.display = "none";
				}
			}

			btn.addEventListener("click", function () {
				hiddenLinks.classList.toggle("hidden");
				btn.classList.toggle("close");
			});

			updateNav();
			window.addEventListener("resize", updateNav);
		}
	}

	/* ---------- Author URLs toggle ---------- */
	var followBtn = document.querySelector(".author__urls-wrapper button");
	if (followBtn) {
		followBtn.addEventListener("click", function () {
			var urls = document.querySelector(".author__urls");
			if (urls) {
				var isHidden =
					urls.style.display === "none" || urls.style.display === "";
				urls.style.display = isHidden ? "block" : "none";
				followBtn.classList.toggle("open");
			}
		});
	}

	/* ---------- Sticky footer ---------- */
	function adjustFooter() {
		var footer = document.querySelector(".page__footer");
		if (footer) {
			document.body.style.marginBottom = footer.offsetHeight + "px";
		}
	}

	var resizeTimer;
	window.addEventListener("resize", function () {
		clearTimeout(resizeTimer);
		resizeTimer = setTimeout(adjustFooter, 100);
	});
	adjustFooter();
})();
