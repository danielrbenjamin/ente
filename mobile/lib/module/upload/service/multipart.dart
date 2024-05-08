import "dart:io";
import "dart:typed_data";

import "package:dio/dio.dart";
import "package:ente_feature_flag/ente_feature_flag.dart";
import "package:logging/logging.dart";
import "package:photos/core/constants.dart";
import "package:photos/db/upload_locks_db.dart";
import "package:photos/models/encryption_result.dart";
import "package:photos/module/upload/model/multipart.dart";
import "package:photos/module/upload/model/xml.dart";
import "package:photos/services/collections_service.dart";
import "package:photos/utils/crypto_util.dart";

class MultiPartUploader {
  final Dio _enteDio;
  final Dio _s3Dio;
  final UploadLocksDB _db;
  final FlagService _featureFlagService;
  late final Logger _logger = Logger("MultiPartUploader");

  MultiPartUploader(
    this._enteDio,
    this._s3Dio,
    this._db,
    this._featureFlagService,
  );

  Future<EncryptionResult> getEncryptionResult(
    String localId,
    String fileHash,
    int collectionID,
  ) async {
    final collectionKey =
        CollectionsService.instance.getCollectionKey(collectionID);
    final result =
        await _db.getFileEncryptionData(localId, fileHash, collectionID);
    final encryptedFileKey = CryptoUtil.base642bin(result.encryptedFileKey);
    final fileNonce = CryptoUtil.base642bin(result.fileNonce);

    final encryptKeyNonce = CryptoUtil.base642bin(result.keyNonce);

    return EncryptionResult(
      key: CryptoUtil.decryptSync(
        encryptedFileKey,
        collectionKey,
        encryptKeyNonce,
      ),
      header: fileNonce,
    );
  }

  int get multipartPartSizeForUpload {
    if (_featureFlagService.internalUser) {
      return multipartPartSizeInternal;
    }
    return multipartPartSize;
  }

  Future<int> calculatePartCount(int fileSize) async {
    // Multipart upload is only enabled for internal users
    // and debug builds till it's battle tested.
    if (!_featureFlagService.internalUser) return 1;

    final partCount = (fileSize / multipartPartSizeForUpload).ceil();
    return partCount;
  }

  Future<MultipartUploadURLs> getMultipartUploadURLs(int count) async {
    try {
      assert(
        _featureFlagService.internalUser,
        "Multipart upload should not be enabled for external users.",
      );
      final response = await _enteDio.get(
        "/files/multipart-upload-urls",
        queryParameters: {
          "count": count,
        },
      );

      return MultipartUploadURLs.fromMap(response.data);
    } on Exception catch (e) {
      _logger.severe('failed to get multipart url', e);
      rethrow;
    }
  }

  Future<void> createTableEntry(
    String localId,
    String fileHash,
    int collectionID,
    MultipartUploadURLs urls,
    String encryptedFilePath,
    int fileSize,
    Uint8List fileKey,
    Uint8List fileNonce,
  ) async {
    final collectionKey =
        CollectionsService.instance.getCollectionKey(collectionID);

    final encryptedResult = CryptoUtil.encryptSync(
      fileKey,
      collectionKey,
    );

    await _db.createTrackUploadsEntry(
      localId,
      fileHash,
      collectionID,
      urls,
      encryptedFilePath,
      fileSize,
      CryptoUtil.bin2base64(encryptedResult.encryptedData!),
      CryptoUtil.bin2base64(fileNonce),
      CryptoUtil.bin2base64(encryptedResult.nonce!),
      partSize: multipartPartSizeForUpload,
    );
  }

  Future<String> putExistingMultipartFile(
    File encryptedFile,
    String localId,
    String fileHash,
    int collectionID,
  ) async {
    final multipartInfo =
        await _db.getCachedLinks(localId, fileHash, collectionID);
    await _db.updateLastAttempted(localId, fileHash, collectionID);

    Map<int, String> etags = multipartInfo.partETags ?? {};

    if (multipartInfo.status == MultipartStatus.pending) {
      // upload individual parts and get their etags
      etags = await _uploadParts(multipartInfo, encryptedFile);
    }

    if (multipartInfo.status != MultipartStatus.completed) {
      // complete the multipart upload
      await _completeMultipartUpload(
        multipartInfo.urls.objectKey,
        etags,
        multipartInfo.urls.completeURL,
      );
    }

    return multipartInfo.urls.objectKey;
  }

  Future<String> putMultipartFile(
    MultipartUploadURLs urls,
    File encryptedFile,
  ) async {
    // upload individual parts and get their etags
    final etags = await _uploadParts(
      MultipartInfo(urls: urls),
      encryptedFile,
    );

    // complete the multipart upload
    await _completeMultipartUpload(urls.objectKey, etags, urls.completeURL);

    return urls.objectKey;
  }

  Future<Map<int, String>> _uploadParts(
    MultipartInfo partInfo,
    File encryptedFile,
  ) async {
    final partsURLs = partInfo.urls.partsURLs;
    final partUploadStatus = partInfo.partUploadStatus;
    final partsLength = partsURLs.length;
    final etags = partInfo.partETags ?? <int, String>{};

    int i = 0;
    final partSize = partInfo.partSize ?? multipartPartSizeForUpload;

    // Go to the first part that is not uploaded
    while (i < (partUploadStatus?.length ?? 0) &&
        (partUploadStatus?[i] ?? false)) {
      i++;
    }

    // Start parts upload
    while (i < partsLength) {
      final partURL = partsURLs[i];
      final isLastPart = i == partsLength - 1;
      final fileSize =
          isLastPart ? encryptedFile.lengthSync() % partSize : partSize;
      _logger.info(
        "Uploading part ${i + 1} / $partsLength of size $fileSize bytes (total size ${encryptedFile.lengthSync()}).",
      );
      final response = await _s3Dio.put(
        partURL,
        data: encryptedFile.openRead(
          i * partSize,
          isLastPart ? null : (i + 1) * partSize,
        ),
        options: Options(
          headers: {
            Headers.contentLengthHeader: fileSize,
          },
        ),
      );

      final eTag = response.headers.value("etag");

      if (eTag?.isEmpty ?? true) {
        throw Exception('ETAG_MISSING');
      }

      etags[i] = eTag!;

      await _db.updatePartStatus(partInfo.urls.objectKey, i, eTag);
      i++;
    }

    await _db.updateTrackUploadStatus(
      partInfo.urls.objectKey,
      MultipartStatus.uploaded,
    );

    return etags;
  }

  Future<void> _completeMultipartUpload(
    String objectKey,
    Map<int, String> partEtags,
    String completeURL,
  ) async {
    final body = convertJs2Xml({
      'CompleteMultipartUpload': partEtags.entries
          .map(
            (e) => PartETag(
              e.key + 1,
              e.value,
            ),
          )
          .toList(),
    }).replaceAll('"', '').replaceAll('&quot;', '');

    try {
      await _s3Dio.post(
        completeURL,
        data: body,
        options: Options(
          contentType: "text/xml",
        ),
      );
      await _db.updateTrackUploadStatus(
        objectKey,
        MultipartStatus.completed,
      );
    } catch (e) {
      Logger("MultipartUpload").severe(e);
      rethrow;
    }
  }
}
