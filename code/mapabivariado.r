# 1. PACKAGES
if (!requireNamespace("pacman", quietly = TRUE)) install.packages("pacman")
pacman::p_load(
	geodata, tidyverse, sf, terra,
	rchelsa, biscale, elevatr, rayshader,
	magick
)

# 2. WORKING DIRECTORY
main_dir <- getwd()

# 3. CHELSA DATA
ids <- c(1, 12) # 1 = mean annual temp, 12 = annual precip

# helper to download CHELSA if files are not present
download_chelsa_data <- function(id, path){
	# Try several possible rchelsa functions; if none present, fail gracefully
	tryCatch({
		if (is.function(rchelsa::get_chelsa)) {
			rchelsa::get_chelsa(categ = "clim", type = "bio", id = id, path = path)
		} else if (is.function(rchelsa::get_chelsa_data)) {
			rchelsa::get_chelsa_data(categ = "clim", type = "bio", id = id, path = path)
		} else if (is.function(rchelsa::get_chelsea)) {
			rchelsa::get_chelsea(categ = "clim", type = "bio", id = id, path = path)
		} else {
			stop("No known download function found in rchelsa")
		}
	}, error = function(e){
		message("CHELSA download via rchelsa failed: ", conditionMessage(e), "\nPlease download the CHELSA files manually and place them in ", path)
		invisible(NULL)
	})
}

# Only download if source files not present
if (!file.exists(file.path(main_dir, "CHELSA_bio10_01.tif")) ||
		!file.exists(file.path(main_dir, "CHELSA_bio10_12.tif"))) {
	lapply(ids, download_chelsa_data, path = main_dir)
}

temp <- terra::rast(file.path(main_dir, "CHELSA_bio10_01.tif"))
prec <- terra::rast(file.path(main_dir, "CHELSA_bio10_12.tif"))
temp_prec <- c(temp, prec)
names(temp_prec) <- c("temperature", "precipitation")

# 4. COUNTRY POLYGON (COLOMBIA)
country_sf <- geodata::gadm(country = "COL", level = 0, path = main_dir) |> sf::st_as_sf()

# 5. DEM (TERRAIN) — mismo CRS desde el inicio
dem <- elevatr::get_elev_raster(
	locations = country_sf,
	z = 6,
	clip = "locations"
) |> terra::rast()

# 6. CRS Y RESAMPLE (orden correcto)
target_crs <- "EPSG:3857"
country_sf <- sf::st_transform(country_sf, target_crs)

# reproyectar rasters a target CRS
# terra::project can accept a CRS string
temp_prec_proj <- terra::project(temp_prec, target_crs)
dem_proj <- terra::project(dem, target_crs)

# terra::crop expects a SpatRaster and either ext/vect; convert sf to vect
country_vect <- terra::vect(country_sf)

# recortar a Colombia y alinear
temp_prec_country <- terra::crop(temp_prec_proj, country_vect, mask = TRUE)
dem_country <- terra::crop(dem_proj, country_vect, mask = TRUE)

# asegurar que tienen la misma resolución y extent
dem_resampled <- terra::resample(dem_country, temp_prec_country, method = "bilinear")

# 7. DATAFRAMES
temp_prec_df <- as.data.frame(temp_prec_country, xy = TRUE)
dem_df <- as.data.frame(dem_resampled, xy = TRUE)
names(dem_df)[3] <- "dem"

ext <- ext(temp_prec_country)
xlim <- c(ext$xmin, ext$xmax)
ylim <- c(ext$ymin, ext$ymax)

# 8. BIVARIATE CLASSES Y PALETA
## Create bivariate classes: x = temperature, y = precipitation
breaks <- biscale::bi_class(
	temp_prec_df, x = temperature, y = precipitation,
	style = "fisher", dim = 3
)
pal <- "DkViolet"

# 9. MAPAS SIN LEYENDA
map_core <- ggplot(breaks) +
	geom_raster(aes(x = x, y = y, fill = bi_class)) +
	biscale::bi_scale_fill(pal = pal, dim = 3, flip_axes = FALSE) +
	coord_fixed(xlim = xlim, ylim = ylim, expand = FALSE) +
	theme_void() +
	theme(panel.background = element_rect(fill = "white", colour = NA),
		  plot.background = element_rect(fill = "white", colour = NA)) +
	# Hide internal legend from the bivariate scale; we'll add a separate square legend later
	guides(fill = "none") +
	theme(legend.position = "none")

dem_map_core <- ggplot(dem_df, aes(x = x, y = y, fill = dem)) +
	geom_raster() +
	coord_fixed(xlim = xlim, ylim = ylim, expand = FALSE) +
	theme_void() +
	# Hide legend in elevation layer to avoid duplicates in the final render
	guides(fill = "none") +
	theme(legend.position = "none")

# 10. 3D RENDER
## 3D RENDER (check that rayshader and rgl device are available)
if (requireNamespace("rayshader", quietly = TRUE)) {
	rayshader::plot_gg(
		ggobj = map_core,
		ggobj_height = dem_map_core,
		width = 7, height = 7,
		windowsize = c(600, 600),
		scale = 100,
		shadow = TRUE, shadow_intensity = 1,
		phi = 87, theta = 0, zoom = .56
	)
	# adjust camera
	try(rayshader::render_camera(zoom = .6), silent = TRUE)
} else {
	message("rayshader not installed; skipping 3D preview.")
}

# 11. RENDER HIGH QUALITY
## High quality render: download HDR if needed and run render_highquality
url <- "https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/brown_photostudio_02_4k.hdr"
hdri_file <- basename(url)
if (!file.exists(hdri_file)) {
	tryCatch(download.file(url, hdri_file, mode = "wb"), error = function(e) message("HDR download failed: ", conditionMessage(e)))
}

if (requireNamespace("rayshader", quietly = TRUE)) {
	tryCatch({
		rayshader::render_highquality(
			filename = "colombia-bivariate-3d.png",
			preview = TRUE,
			light = FALSE,
			environment_light = hdri_file,
			intensity = 1,
			rotate_env = 90,
			parallel = TRUE,
			width = 2000, height = 2000,
			interactive = FALSE
		)
	}, error = function(e) message("render_highquality failed: ", conditionMessage(e)))
} else {
	message("rayshader not installed; skipping high-quality render.")
}

# 12. LEYENDA (overlay con magick)
legend <- biscale::bi_legend(
	pal = pal, flip_axes = FALSE, dim = 3,
	xlab = "Temperature (°C)", ylab = "Precipitation (mm)", size = 8
)
ggsave("legend.png", legend, width = 2.2, height = 2.2, dpi = 300, bg = "transparent")

if (file.exists("colombia-bivariate-3d.png") && file.exists("legend.png")) {
	img <- image_read("colombia-bivariate-3d.png")
	leg <- image_read("legend.png")
	out <- image_composite(img, leg, offset = "+60+60")
	image_write(out, path = "colombia-bivariate-3d-legend.png")
} else {
	message("Either the rendered PNG or legend.png is missing; skipping overlay.")
}